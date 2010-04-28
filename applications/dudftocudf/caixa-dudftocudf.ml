(**************************************************************************************)
(*  Copyright (C) 2009 Pietro Abate <pietro.abate@pps.jussieu.fr>                     *)
(*  Copyright (C) 2009 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

open ExtLib
open Common

module L = Xml.LazyList 

module Options = struct
  open OptParse

  let debug = StdOpt.store_true ()
  let outdir = StdOpt.str_option ()
  let problemid = StdOpt.str_option ()

  let description = "Convert Caixa Magica Dudf files to Cudf format"
  let options = OptParser.make ~description:description ()

  open OptParser ;;
  add options ~short_name:'d' ~long_name:"debug" ~help:"Print debug information" debug;
  add options ~short_name:'o' ~long_name:"outdir" ~help:"Output directory" outdir;
  add options                 ~long_name:"id" ~help:"Problem id" problemid;
end

(* ========================================= *)

let amp_re = Pcre.regexp "&amp;" ;;
let lt_re = Pcre.regexp "&lt;" ;;
let gt_re = Pcre.regexp "&gt;" ;;
let quot_re = Pcre.regexp "&quot;" ;;

let decode str =
  let str = Pcre.replace ~rex:amp_re ~templ:"&" str in
  let str = Pcre.replace ~rex:lt_re ~templ:"<" str in
  let str = Pcre.replace ~rex:gt_re ~templ:">" str in
  let str = Pcre.replace ~rex:quot_re ~templ:"\"" str in
  str 
;;

let rel_of_string = function
  |"<<" | "<" -> `Lt
  |"<=" -> `Leq
  |"=" | "==" -> `Eq
  |">=" -> `Geq
  |">>" | ">" -> `Gt
  |"ALL" -> `ALL
  |s -> (Printf.eprintf "Invalid op %s" s ; assert false)

let parse_vpkg vpkg =
  match Pcre.full_split ~rex:(Pcre.regexp "<=|>=|=|<|>") vpkg with
  |(Pcre.Text n)::_ when String.starts_with n "rpmlib(" -> None
  |[Pcre.Text n] -> Some(vpkg,(`ALL,""))
  |[Pcre.Text n;Pcre.Delim sel;Pcre.Text v] -> Some(n,(rel_of_string sel,v))
  |_ -> (Printf.eprintf "%s\n%!" vpkg ; assert false)

let parse_string = function
  |Json_type.String s -> s
  |_ -> assert false

let to_list = function
  |Json_type.Array l ->
      List.map (function Json_type.String s -> s | _ -> assert false) l
  |_ -> assert false

let read_status str = 
  let aux = function
    |Json_type.Object [("package-status", Json_type.Array packagelist )] ->
        List.filter_map (function
          |Json_type.Array l ->
              let a = Array.of_list l in
              begin try
              let v = Printf.sprintf "%s-%s" (parse_string a.(1)) (parse_string a.(2)) in
              Some 
              {
                Rpm.Packages.name = parse_string a.(0);
                Rpm.Packages.version = v;
                Rpm.Packages.depends = [List.filter_map parse_vpkg (to_list a.(3))];
                Rpm.Packages.conflicts = List.filter_map parse_vpkg (to_list a.(7));
                Rpm.Packages.provides = List.filter_map parse_vpkg (to_list a.(5));
                Rpm.Packages.obsoletes = [];
                Rpm.Packages.files = []
              }
              with Invalid_argument("index out of bounds") -> (
                Util.print_warning "%s" (Json_io.string_of_json (Json_type.Array l));
                None)
              end
          |_ -> assert false
        ) packagelist
    |_ -> assert false
  in aux (Json_io.json_of_string str)

(* ========================================= *)

let has_children nodelist tag =
  try match nodelist with
    |t::_ when (Xml.tag t) = tag -> true
    |_ -> false
  with Xml.Not_element(_) -> false
;;

let parsepackagelist = function
  |(Some t,Some fname,url,[inc]) when has_children [inc] "include" ->
      let href = Xml.attrib inc "href" in
      (t,fname,url, Dudfxml.pkgget ~compression:Dudfxml.Cz fname href)
  |(Some t,Some fname,url,[cdata]) -> (t,fname,url,Xml.cdata cdata)
  |(Some t,Some fname,url,[]) -> (t,fname,url,"")
  |(Some t,Some fname,url,_) ->
      (Printf.eprintf "Warning : Unknown format for package-list element %s %s\n" t fname; exit 1)
  |_ -> assert false
;;

(* ========================================= *)

open Dudfxml.XmlDudf

let main () =
  at_exit (fun () -> Util.dump Format.err_formatter);
  Random.self_init () ;
  let input_file =
    match OptParse.OptParser.parse_argv Options.options with
    |[h] -> h
    |_ -> (Printf.eprintf "too many arguments" ; exit 1)
  in
  if OptParse.Opt.get Options.debug then Boilerplate.enable_debug () ;
  Util.print_info "parse xml";

  let dudfdoc = Dudfxml.parse input_file in
  let uid = dudfdoc.uid in
  let status =
    (* XXX here I want cdata !!! *)
    match dudfdoc.problem.packageStatus.st_installer with
    |[status] -> decode(Dudfxml.content_to_string status) (* Xml.fold (fun a x -> a^(Xml.cdata x)) "" status *)
    |_ -> Printf.eprintf "Warning: wrong status" ; ""
  in
  let packagelist = 
    List.map (fun pl -> parsepackagelist pl) dudfdoc.problem.packageUniverse
  in
  let action = dudfdoc.problem.action in
  let preferences = dudfdoc.problem.desiderata in

  Util.print_info "convert to dom ... ";

  let extras_property = [
    ("Size", ("size", `Nat (Some 0)));
    ("Installed-Size", ("installedsize", `Nat (Some 0)));
    ("Maintainer", ("maintainer", `String None))]
  in
  let extras = List.map fst extras_property in

  Util.print_info "parse all packages";
  let all_packages =
    List.fold_left (fun acc (_,_,_,contents) ->
      let ch = IO.input_string contents in
      let l = Rpm.Packages.Synthesis.parse_packages_in (fun x -> x) ch in
      let _ = IO.close_in ch in
      List.fold_right Rpm.Packages.Set.add l acc
    ) Rpm.Packages.Set.empty packagelist
  in

  Util.print_info "installed packages";
  let installed_packages =
    let l = read_status status in
    List.fold_left (fun s pkg -> Rpm.Packages.Set.add pkg s) Rpm.Packages.Set.empty l
  in

  Util.print_info "union";
  let l = Rpm.Packages.Set.elements (Rpm.Packages.Set.union all_packages installed_packages) in
  let tables = Rpm.Rpmcudf.init_tables l in

  let installed =
    let h = Hashtbl.create 1031 in
    Rpm.Packages.Set.iter (fun pkg ->
      Hashtbl.add h (pkg.Rpm.Packages.name,pkg.Rpm.Packages.version) ()
    ) installed_packages
    ;
    h
  in
  
  Util.print_info "convert";
  let pl =
    List.map (fun pkg ->
      let inst = Hashtbl.mem installed (pkg.Rpm.Packages.name,pkg.Rpm.Packages.version) in
      Rpm.Rpmcudf.tocudf tables ~inst:inst pkg
    ) l
  in

  let universe = Cudf.load_universe pl in

  Util.print_info "request";
  let request = Cudf.default_request in

  Util.print_info "dump";
  let oc =
    if OptParse.Opt.is_set Options.outdir then begin
      let dirname = OptParse.Opt.get Options.outdir in
      let file =
        let s = Filename.basename input_file in
        try Filename.chop_extension s with Invalid_argument _ -> s
      in
      if not(Sys.file_exists dirname) then Unix.mkdir dirname 0o777 ;
      open_out (Filename.concat dirname (file^".cudf"))
    end else stdout
  in
  let preamble = Cudf.default_preamble in
  Cudf_printer.pp_cudf (Format.formatter_of_out_channel oc) (preamble, universe, request)
;;

main ();;

