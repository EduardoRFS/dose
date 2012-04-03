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

(** Library of additional functions for the CUDF format. *)

(** {3 Remembering two Ocaml standard library modules, whose names will be overriden by opening Extlib}*)

(** Original hashtable module from Ocaml standard library. *)
module OCAMLHashtbl = Hashtbl

(** Original set module from Ocaml standard library. *)
(* WTF? I don't see any Set module in ExtLib... *)
module OCAMLSet = Set

open ExtLib

(** {3 Include internal debugging functions for this module (debug, info, warning, fatal).} *)
include Util.Logging(struct let label = __FILE__ end) ;;

(** the id of a package 
    TODO: check if used anywhere. *)
let id pkg = (pkg.Cudf.package,pkg.Cudf.version)

(** {2 Basic comparison operations for packages} *)

(** Equality test: two CUDF packages are equal if their names and versions are equal. *)
let equal = Cudf.(=%)

(** Compare function: compares two CUDF packages using standard CUDF comparison operator (i.e. comparing by their name and version). *)
let compare = Cudf.(<%)

(** {2 Specialized data structures for CUDF packages} *)

(** A hash function for CUDF packages, using only their name and version. *)
let hash p = Hashtbl.hash (p.Cudf.package,p.Cudf.version)

(** Data structures: *)

(** Specialized hashtable for CUDF packages. *)
module Cudf_hashtbl =
  OCAMLHashtbl.Make(struct
    type t = Cudf.package
    let equal = equal
    let hash = hash
  end)

(** Specialized set data structure for CUDF packages. *)
module Cudf_set =
  OCAMLSet.Make(struct
    type t = Cudf.package
    let compare = compare
  end)

(* *)
let to_set l = List.fold_right Cudf_set.add l Cudf_set.empty

(** {2 Encode and decode a string functions. } *)
(** TODO: What are these functions doing in this module? *)

(** Encode a string.

    Replaces all the "not allowed" characters
    with their ASCII code (in hexadecimal format),
    prefixed with a '%' sign.
    
    Only "allowed" characters are letters, numbers and these: [@/+().-],
    all the others are replaced.
    
    Examples:
    {ul
    {li [encode "ab"  = "ab"]}
    {li [encode "|"   = "%7c"]}
    {li [encode "a|b" = "a%7cb"]}
    }
*)
let encode s =
  let not_allowed_regex = Pcre.regexp "[^a-zA-Z0-9@/+().-]"
  in
  (*  "hex_char char" returns the ASCII code of the given character
      in the hexadecimal form, prefixed with the '%' sign.
      e.g. hex_char '+' = "%2b" *)
  let hex_char char = Printf.sprintf "%%%x" (Char.code char)
  in
  let hex_string s = String.replace_chars hex_char s
  in
  Pcre.substitute ~rex:not_allowed_regex ~subst:hex_string s

(** Decode a string. Opposite of the [encode] function.

    Replaces all the encoded "not allowed" characters
    in the string by their original (i.e. not encoded) versions.

    Examples:
    {ul
    {li [decode "ab" = "ab"]}
    {li [decode "%7c" = "|"]}
    {li [decode "a%7cb" = "a|b"]}
    }
*)
let decode s =
  let encoded_char_regex = Pcre.regexp "%[0-9a-f][0-9a-f]" 
  in
  (* "unhex_char encoded" returns the decoded form 
      of a character, which was encoded using 
      the hex_char function.
      e.g. unhex_char "%2b" = '+' *)
  let unhex_char encoded_char =
    let ascii_code_hex = String.sub encoded_char 1 2 in
    let ascii_code_dec = int_of_string ("0x" ^ ascii_code_hex) in
    String.make 1 (Char.chr ascii_code_dec)
  in
  (* Decode all the encoded chars in the string one by one. *)
  Pcre.substitute ~rex:encoded_char_regex ~subst:unhex_char s

(** {2 Formatting, printing, converting to string. } *)

let buf = Buffer.create 1024

let buf_formatter =
  let fmt = Format.formatter_of_buffer buf in
    Format.pp_set_margin fmt max_int;
    fmt

let string_of pp arg =
  Buffer.clear buf;
  ignore(pp buf_formatter arg);
  Format.pp_print_flush buf_formatter ();
  Buffer.contents buf

let pp_version fmt pkg =
  try Format.fprintf fmt "%s" (Cudf.lookup_package_property pkg "number")
  with Not_found -> Format.fprintf fmt "%d" pkg.Cudf.version

let pp_package fmt pkg =
  Format.fprintf fmt "%s (= %a)" (decode pkg.Cudf.package) pp_version pkg

let string_of_version = string_of pp_version
let string_of_package = string_of pp_package

module StringSet = OCAMLSet.Make(String)

let pkgnames universe =
  Cudf.fold_packages (fun names pkg ->
    StringSet.add pkg.Cudf.package names
  ) StringSet.empty universe

(** {2 Additional functions on the CUDF data type. } *)

let add_properties preamble l =
  List.fold_left (fun pre prop ->
    {pre with Cudf.property = prop :: pre.Cudf.property }
  ) preamble l

let is_essential pkg =
  try (Cudf.lookup_package_property pkg "essential") = "yes"
  with Not_found -> false


(** build an hash table that associates (package name, String version) to
 * cudf packages *)
let realversionmap pkglist =
  let h = Hashtbl.create (5 * (List.length pkglist)) in
  List.iter (fun pkg ->
    Hashtbl.add h (pkg.Cudf.package,string_of_version pkg) pkg
  ) pkglist ;
  h

let vartoint = Cudf.uid_by_package 
let inttovar = Cudf.package_by_uid

let pkgid p = (p.Cudf.package, p.Cudf.version)

let add_to_package_list h n p =
  try let l = Hashtbl.find h n in l := p :: !l
  with Not_found -> Hashtbl.add h n (ref [p])

let get_package_list h n = try !(Hashtbl.find h n) with Not_found -> []

let unique l = 
  List.rev (List.fold_left (fun results x -> 
    if List.mem x results then results 
    else x::results) [] l
  )
;;
let normalize_set (l : int list) = unique l

(* (pkgname,constr) -> pkg *)
let who_provides univ (pkgname,constr) = 
  let pkgl = Cudf.lookup_packages ~filter:constr univ pkgname in
  let prol = Cudf.who_provides ~installed:false univ (pkgname,constr) in
  pkgl @ (List.map fst prol)

(* vpkg -> id list *)
let resolve_vpkg_int univ vpkg =
  List.map (Cudf.uid_by_package univ) (who_provides univ vpkg)

(* vpkg list -> id list *)
let resolve_vpkgs_int univ vpkgs =
  normalize_set (List.flatten (List.map (resolve_vpkg_int univ) vpkgs))

(* vpkg list -> pkg list *)
let resolve_deps univ vpkgs =
  List.map (Cudf.package_by_uid univ) (resolve_vpkgs_int univ vpkgs)

(* pkg -> pkg list list *)
let who_depends univ pkg = 
  List.map (resolve_deps univ) pkg.Cudf.depends

let who_conflicts conflicts_packages univ pkg = 
  if (Hashtbl.length conflicts_packages) = 0 then
    warning "Either there are no conflicting packages in the universe or you
CudfAdd.init_conflicts was not invoked before calling CudfAdd.who_conflicts";
  let i = Cudf.uid_by_package univ pkg in
  List.map (Cudf.package_by_uid univ) (get_package_list conflicts_packages i)
;;

let init_conflicts univ =
  let conflict_pairs = Hashtbl.create 1023 in
  let conflicts_packages = Hashtbl.create 1023 in
  Cudf.iteri_packages (fun i p ->
    List.iter (fun n ->
      let pair = (min n i, max n i) in
      if n <> i && not (Hashtbl.mem conflict_pairs pair) then begin
        Hashtbl.add conflict_pairs pair ();
        add_to_package_list conflicts_packages i n;
        add_to_package_list conflicts_packages n i
      end
    )
    (resolve_vpkgs_int univ p.Cudf.conflicts)
  ) univ;
  conflicts_packages
;;

(* here we assume that the id given by cudf is a sequential and dense *)
let compute_pool universe = 
  let size = Cudf.universe_size universe in
  let conflicts = init_conflicts universe in
  let c = Array.init size (fun i -> get_package_list conflicts i) in
  let d =
    Array.init size (fun i ->
      let p = inttovar universe i in
      List.map (resolve_vpkgs_int universe) p.Cudf.depends
    )
  in
  (d,c)
;;

let cudfop = function
  |Some(("<<" | "<"),v) -> Some(`Lt,v)
  |Some((">>" | ">"),v) -> Some(`Gt,v)
  |Some("<=",v) -> Some(`Leq,v)
  |Some(">=",v) -> Some(`Geq,v)
  |Some("=",v) -> Some(`Eq,v)
  |Some("ALL",v) -> None
  |None -> None
  |Some(c,v) -> fatal "%s %s" c v
