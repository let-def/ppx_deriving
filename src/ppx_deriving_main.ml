open Migrate_parsetree

open Asttypes
open Parsetree
open Ast_helper

let raise_errorf = Ppx_deriving.raise_errorf

let dynlink ?(loc=Location.none) filename =
  let filename = Dynlink.adapt_filename filename in
  try
    Dynlink.loadfile filename
  with Dynlink.Error error ->
    raise_errorf ~loc "Cannot load %s: %s" filename (Dynlink.error_message error)

let init_findlib = lazy (
  Findlib.init ();
  Findlib.record_package Findlib.Record_core "ppx_deriving.api";
)

let load_ocamlfind_package ?loc pkg =
  Lazy.force init_findlib;
  try
    Fl_dynload.load_packages [pkg]
  with Dynlink.Error error ->
    raise_errorf ?loc "Cannot load %s: %s" pkg (Dynlink.error_message error)

let load_plugin ?loc plugin =
  let len = String.length plugin in
  let pkg_prefix = "package:" in
  let pkg_prefix_len = String.length pkg_prefix in
  if len >= pkg_prefix_len &&
     String.sub plugin 0 pkg_prefix_len = pkg_prefix then
    let pkg = String.sub plugin pkg_prefix_len (len - pkg_prefix_len) in
    load_ocamlfind_package ?loc pkg
  else
    dynlink ?loc plugin

let get_plugins cookies =
  match Driver.get_cookie cookies "ppx_deriving" Versions.ocaml_405 with
  | Some { pexp_desc = Pexp_tuple exprs } ->
    exprs |> List.map (fun expr ->
      match expr with
      | { pexp_desc = Pexp_constant (Pconst_string (file, None)) } -> file
      | _ -> assert false)
  | Some _ -> assert false
  | None -> []

let add_plugins cookies plugins =
  let loaded  = get_plugins cookies in
  let plugins = List.filter (fun file -> not (List.mem file loaded)) plugins in
  List.iter load_plugin plugins;
  let loaded  = loaded @ plugins in
  Driver.set_cookie cookies "ppx_deriving" Versions.ocaml_405
    (Exp.tuple (List.map (fun file -> Exp.constant (Pconst_string (file, None))) loaded))

let plugins_to_load = ref []

let args_spec = [
  ("-deriving-plugin",
   Arg.String (fun str -> plugins_to_load := str :: !plugins_to_load),
   " Deriving plugin to load"
  )
]

let rewriter config cookies =
  get_plugins cookies |> List.iter load_plugin;
  let plugins = List.rev !plugins_to_load in
  plugins_to_load := [];
  add_plugins cookies plugins;
  let structure mapper = function
    | [%stri [@@@findlib.ppxopt [%e? { pexp_desc = Pexp_tuple (
        [%expr "ppx_deriving"] :: elems) }]]] :: rest ->
      let extract = function
        | { pexp_desc = Pexp_constant (Pconst_string (file, None))} -> file
        | _ -> assert false
      in
      let args = Array.of_list (Sys.argv.(0) :: List.map extract elems) in
      let anon_fun arg =
        raise (Arg.Bad ("Unexpected argument in cookie: " ^ arg)) in
      Arg.parse_argv ~current:(ref 0) args args_spec anon_fun "";
      add_plugins cookies !plugins_to_load;
      plugins_to_load := [];
      mapper.Ast_mapper.structure mapper rest
    | items -> Ppx_deriving.mapper.Ast_mapper.structure mapper items in
  { Ppx_deriving.mapper with Ast_mapper.structure }

let () =
  Driver.register ~name:"ppx_deriving" ~args:args_spec
    Versions.ocaml_405 rewriter;
  Driver.run_main ()

