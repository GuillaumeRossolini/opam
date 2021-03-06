(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2015 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open OpamCompat
open OpamTypes
open OpamStateTypes
open OpamStd.Op
open OpamPackage.Set.Op

let log fmt = OpamConsole.log "LIST" fmt
let slog = OpamConsole.slog

type dependency_toggles = {
  recursive: bool;
  depopts: bool;
  build: bool;
  test: bool;
  doc: bool;
  dev: bool;
}

let default_dependency_toggles = {
  recursive = false;
  depopts = false;
  build = true;
  test = false;
  doc = false;
  dev = false;
}

type pattern_selector = {
  case_sensitive: bool;
  exact: bool;
  glob: bool;
  fields: string list;
  ext_fields: bool;
}

let default_pattern_selector = {
  case_sensitive = false;
  exact = false;
  glob = true;
  fields = ["name"; "descr"; "flags"];
  ext_fields = false;
}

type selector =
  | Any
  | Installed
  | Root
  | Compiler
  | Available
  | Installable
  | Pinned
  | Depends_on of dependency_toggles * atom list
  | Required_by of dependency_toggles * atom list
  | Solution of dependency_toggles * atom list
  | Pattern of pattern_selector * string
  | Atoms of atom list
  | Flag of package_flag
  | Tag of string
  | From_repository of repository_name list

let string_of_selector =
  let (%) s col = OpamConsole.colorise col s in
  function
  | Any -> "any" % `cyan
  | Installed -> "installed" % `cyan
  | Root -> "root" % `cyan
  | Compiler -> "base" % `cyan
  | Available -> "available" % `cyan
  | Installable -> "installable" % `cyan
  | Pinned -> "pinned" % `cyan
  | Depends_on (tog,atoms) ->
    Printf.sprintf "%s(%s)"
      ((if tog.recursive then "rec-depends-on" else "depends-on") % `blue)
      (OpamStd.List.concat_map " " OpamFormula.short_string_of_atom atoms
       % `bold)
  | Required_by (tog,atoms) ->
    Printf.sprintf "%s(%s)"
      ((if tog.recursive then "rec-required-by" else "required-by") % `blue)
      (OpamStd.List.concat_map " " OpamFormula.short_string_of_atom atoms
       % `bold)
  | Solution (_tog,atoms) ->
    Printf.sprintf "%s(%s)"
      ("solution" % `blue)
      (OpamStd.List.concat_map " " OpamFormula.short_string_of_atom atoms
       % `bold)
  | Pattern (sel,str) ->
    let str = if sel.exact then str else Printf.sprintf "*%s*" str in
    let fctname = if sel.glob then "match" else "exact-match" in
    let fctname =
      match sel.fields with
      | [] ->  Printf.sprintf "none-%s" fctname
      | [fld] ->  Printf.sprintf "%s-%s" fld fctname
      | _ -> fctname
    in
    Printf.sprintf "%s(%s)" (fctname % `green) (str % `bold)
  | Atoms atoms ->
    OpamStd.List.concat_map ~left:"(" ~right:")" " | "
      (fun a -> OpamFormula.short_string_of_atom a % `bold) atoms
  | Flag fl ->
    Printf.sprintf "%s(%s)" ("has-flag" % `green)
      (OpamTypesBase.string_of_pkg_flag fl % `bold)
  | Tag t ->
    Printf.sprintf "%s(%s)" ("has-tag" % `green) (t % `bold)
  | From_repository r ->
    Printf.sprintf "%s(%s)" ("from-repository" % `magenta)
      (OpamStd.List.concat_map " " OpamRepositoryName.to_string r % `bold)

let string_of_formula =
  OpamFormula.string_of_formula string_of_selector

let get_opam st nv =
  match OpamSwitchState.opam_opt st nv with
  | Some o -> o
  | None -> OpamFile.OPAM.create nv

let packages_of_atoms st atoms =
  atoms |>
  OpamSolution.sanitize_atom_list ~permissive:true st |>
  OpamFormula.packages_of_atoms (st.packages ++ st.installed)

let package_dependencies st tog nv =
  get_opam st nv |>
  OpamPackageVar.all_depends
    ~build:tog.build ~test:tog.test ~doc:tog.doc ~dev:tog.dev
    ~depopts:tog.depopts
    st

let atom_dependencies st tog atoms =
  atoms |>
  OpamFormula.packages_of_atoms (st.packages ++ st.installed) |> fun pkgs ->
  OpamPackage.Set.fold (fun nv acc ->
      OpamFormula.ors [acc; package_dependencies st tog nv])
    pkgs OpamFormula.Empty

let get_universe st tog =
  let universe =
    OpamSwitchState.universe st
      ~test:tog.test ~doc:tog.doc
      ~requested:(OpamPackage.names_of_packages st.packages)
      Depends
  in
  if tog.dev then { universe with u_dev = st.packages }
  else universe

let rec value_strings value =
  let module SS = OpamStd.String.Set in
  match value with
  | Bool _ | Int _ -> SS.empty
  | Ident (_, s) -> SS.singleton s
  | String (_, s) -> SS.singleton s
  | Relop (_, _, v1, v2)
  | Logop (_, _, v1, v2)
  | Env_binding (_, v1, _, v2) ->
    SS.union (value_strings v1) (value_strings v2)
  | Prefix_relop (_, _, v)
  | Pfxop (_, _, v) ->
    value_strings v
  | List (_, l)
  | Group (_, l) ->
    List.fold_left (fun acc v -> SS.union acc (value_strings v))
      SS.empty l
  | Option (_, v, vl) ->
    List.fold_left (fun acc v -> SS.union acc (value_strings v))
      (value_strings v) vl

let apply_selector ~base st = function
  | Any -> base
  | Installed -> st.installed
  | Root -> st.installed_roots
  | Compiler -> st.compiler_packages
  | Available -> Lazy.force st.available_packages
  | Installable ->
    OpamSolver.installable
      (OpamSwitchState.universe st ~requested:OpamPackage.Name.Set.empty
         Depends)
  | Pinned -> OpamPinned.packages st
  | (Required_by ({recursive=true; _} as tog, atoms)
    | Depends_on ({recursive=true; _} as tog, atoms)) as direction ->
    let deps_fun = match direction with
      | Required_by _ -> OpamSolver.dependencies
      | Depends_on _ -> OpamSolver.reverse_dependencies
      | _ -> assert false
    in
    deps_fun ~depopts:tog.depopts ~build:tog.build
      ~installed:false ~unavailable:true
      (get_universe st tog)
      (packages_of_atoms st atoms)
    |> OpamPackage.Set.of_list
  | Required_by (tog, atoms) ->
    atom_dependencies st tog atoms |>
    OpamFormula.atoms |>
    OpamFormula.packages_of_atoms base
  | Depends_on (tog, atoms) ->
    let packages = packages_of_atoms st atoms in
    OpamPackage.Set.filter (fun nv ->
        let deps = package_dependencies st tog nv |> OpamFormula.atoms in
        OpamPackage.Set.exists
          (fun nv -> List.exists (fun at -> OpamFormula.check at nv) deps)
          packages)
      base
  | Solution (tog, atoms) ->
    let universe = get_universe st tog in
    let universe =
      { universe
        with u_installed = OpamPackage.Set.empty;
             u_installed_roots = OpamPackage.Set.empty }
    in
    (match OpamSolver.resolve universe ~orphans:OpamPackage.Set.empty
             (OpamSolver.request ~install:atoms ()) with
    | Success s -> OpamSolver.new_packages s
    | Conflicts cs ->
      failwith @@
      Printf.sprintf "No solution%s for %s:\n%s"
        (if tog.depopts then " including optional dependencies" else "")
        (OpamFormula.string_of_atoms atoms)
        (OpamCudf.string_of_conflict
           (OpamSwitchState.unavailable_reason st) cs))
  | Pattern (psel, pat) ->
    let re =
      if psel.glob then Re_glob.glob ~expand_braces:true pat
      else Re.str pat
    in
    let re = if psel.case_sensitive then Re.case re else re in
    let re = if psel.exact then Re.seq [Re.bos; re; Re.eos] else re in
    let re = Re.compile re in
    let content_strings nv =
      let opam = get_opam st nv in
      if psel.fields = [] then
        List.map (fun (_,v) -> value_strings v) (OpamFile.OPAM.to_list opam)
      else
      try
        List.map
          (fun f -> match OpamFile.OPAM.print_field_as_syntax f opam with
             | None -> OpamStd.String.Set.empty
             | Some v -> value_strings v)
          psel.fields
      with Not_found ->
        OpamConsole.error_and_exit "Unrecognised field in selection %s"
          (String.concat ", " psel.fields)
    in
    OpamPackage.Set.filter
      (fun nv -> List.exists (OpamStd.String.Set.exists (Re.execp re))
          (content_strings nv))
      base
  | Atoms atoms ->
    OpamFormula.packages_of_atoms base atoms
  | Flag f ->
    OpamPackage.Set.filter (fun nv ->
        get_opam st nv |> OpamFile.OPAM.has_flag f)
      base
  | Tag t ->
    OpamPackage.Set.filter (fun nv ->
        get_opam st nv |> List.mem t @* OpamFile.OPAM.tags)
      base
  | From_repository repos ->
    let rt = st.switch_repos in
    let rec aux = function
      | [] -> OpamPackage.Set.empty
      | r :: rl ->
        let packages =
          OpamPackage.keys (OpamRepositoryName.Map.find r rt.repo_opams)
        in
        if List.mem r repos then OpamPackage.Set.union packages (aux rl)
        else OpamPackage.Set.diff (aux rl) packages
    in
    aux (OpamSwitchState.repos_list st)

let rec filter ~base st = function
  | Empty -> base
  | Atom select -> apply_selector ~base st select
  | Block b -> filter ~base st b
  | And (a, b) -> filter ~base st a %% filter ~base st b
  | Or (a, b) -> filter ~base st a ++ filter ~base st b

type output_format =
  | Name
  | Version
  | Package
  | Synopsis
  | Synopsis_or_target
  | Description
  | Field of string
  | Installed_version
  | Pinning_target
  | Raw
  | All_installed_versions
  | Available_versions
  | All_versions
  | Repository
  | Installed_files

let default_list_format = [Name; Installed_version; Synopsis_or_target]

let disp_header = function
  | Name -> "Name"
  | Version -> "Version"
  | Package -> "Package"
  | Synopsis | Synopsis_or_target -> "Synopsis"
  | Description -> "Description"
  | Field s -> String.capitalize_ascii s
  | Installed_version -> "Installed"
  | Pinning_target -> "Pin"
  | Raw -> "Metadata"
  | All_installed_versions -> "Installed versions"
  | Available_versions -> "Available versions"
  | All_versions -> "Versions"
  | Repository -> "Repository"
  | Installed_files -> "Installed files"

let field_names = [
  Name, "name";
  Version, "version";
  Package, "package";
  Synopsis, "synopsis";
  Synopsis_or_target, "synopsis-or-target";
  Description, "description";
  Field "<field>", "<field>:";
  Installed_version, "installed-version";
  Pinning_target, "pin";
  Raw, "opam-file";
  All_installed_versions, "all-installed-versions";
  Available_versions, "available-versions";
  All_versions, "all-versions";
  Repository, "repository";
  Installed_files, "installed-files";
]

let string_of_field = function
  | Field s -> s^":"
  | f -> List.assoc f field_names

let field_of_string =
  let names_fields = List.map (fun (a,b) -> b, a) field_names in
  fun s ->
    if OpamStd.String.ends_with ~suffix:":" s then
      Field (OpamStd.String.remove_suffix ~suffix:":" s)
    else
    try List.assoc s names_fields
    with Not_found ->
      OpamConsole.error_and_exit "No printer for %S%s" s
        (if not (OpamStd.String.ends_with ~suffix:":" s) &&
            List.mem_assoc s (OpamFile.OPAM.fields)
         then Printf.sprintf ". Did you mean the opam field \"%s:\" \
                              (with a colon) ?" s
         else "")

let version_color st nv =
  let installed = (* (in any switch) *)
    OpamGlobalState.installed_versions st.switch_global nv.name
  in
  let is_available nv = (* Ignore unavailability due to pinning *)
    try
      OpamFilter.eval_to_bool ~default:false
        (OpamPackageVar.resolve_switch_raw ~package:nv st.switch_global
           st.switch st.switch_config)
        (OpamFile.OPAM.available (get_opam st nv))
    with Not_found -> false
  in
  if OpamPackage.Set.mem nv st.installed then [`bold;`magenta] else
    (if OpamPackage.Map.mem nv installed then [`bold] else []) @
    (if is_available nv then [] else [`crossed;`red])

let mini_field_printer ?(prettify=false) ?(normalise=false) =
  if normalise then OpamPrinter.Normalise.value else
  function
  | String (_, s) -> s
  | List (_, l) when prettify &&
                     List.for_all (function String _ -> true | _ -> false) l ->
    OpamStd.List.concat_map ", " (function String (_, s) -> s | _ -> assert false) l
  | List (_, l) -> OpamPrinter.value_list l
  | f -> OpamPrinter.Normalise.value f

let detail_printer ?prettify ?normalise st nv =
  let open OpamStd.Option.Op in
  let (%) s cols = OpamConsole.colorise' cols s in
  let root_sty =
    if OpamPackage.Set.mem nv st.installed_roots then [`underline]
    else []
  in
  function
  | Name -> OpamPackage.Name.to_string nv.name % (`bold :: root_sty)
  | Version -> OpamPackage.Version.to_string nv.version % version_color st nv
  | Package ->
    (OpamPackage.name_to_string nv % (`bold :: root_sty)) ^
    ("." ^ OpamPackage.version_to_string nv) % root_sty
  | Synopsis ->
    (get_opam st nv |>
     OpamFile.OPAM.descr >>| OpamFile.Descr.synopsis)
    +! ""
  | Synopsis_or_target ->
    (match OpamPinned.package_opt st nv.name with
     | Some nv ->
       let opam = get_opam st nv in
       if Some opam = OpamPackage.Map.find_opt nv st.repos_package_index then
         Printf.sprintf "pinned to version %s"
           (OpamPackage.Version.to_string nv.version % [`blue])
       else
         Printf.sprintf "pinned to version %s at %s"
           (OpamPackage.Version.to_string nv.version % [`blue])
           (OpamStd.Option.to_string ~none:"(local metadata only)"
              (fun u -> OpamUrl.to_string u % [`underline])
              (OpamFile.OPAM.get_url opam))
     | None ->
       (get_opam st nv |>
        OpamFile.OPAM.descr >>| OpamFile.Descr.synopsis)
       +! "")
  | Description ->
    (get_opam st nv |>
     OpamFile.OPAM.descr >>|
     OpamFile.Descr.body)
    +! ""
  | Field f ->
    (try
       List.assoc f (OpamFile.OPAM.to_list (get_opam st nv)) |>
       mini_field_printer ?prettify ?normalise
     with Not_found -> "")
  | Installed_version ->
    (try OpamPackage.package_of_name st.installed nv.name |> fun inst_nv ->
         OpamPackage.version_to_string inst_nv |> fun s ->
         if OpamPackage.Set.mem inst_nv st.pinned then s % [`blue] else
         if OpamPackage.has_name st.pinned nv.name then s % [`bold;`red] else
         if nv <> inst_nv &&
            not (OpamPackage.Set.mem inst_nv st.compiler_packages)
         then s % [`bold;`yellow] else
           s % [`magenta]
     with Not_found -> "--" % [`cyan])
  | Pinning_target ->
    if OpamPackage.Set.mem nv st.pinned then
      let opam = get_opam st nv in
      OpamStd.Option.to_string ~none:"--" OpamUrl.to_string
        (OpamFile.OPAM.get_url opam)
    else ""
  | Raw -> OpamFile.OPAM.write_to_string (get_opam st nv)
  | All_installed_versions ->
    OpamGlobalState.installed_versions st.switch_global nv.name |>
    OpamPackage.Map.mapi (fun nv switches ->
        Printf.sprintf "%s [%s]"
          (OpamPackage.version_to_string nv % version_color st nv)
          (String.concat " " (List.map OpamSwitch.to_string switches))) |>
    OpamPackage.Map.values |>
    String.concat "  "
  | Available_versions ->
    let available =
      OpamPackage.packages_of_name (Lazy.force st.available_packages) nv.name
    in
    OpamStd.List.concat_map "  " (fun nv ->
        OpamPackage.Version.to_string nv.version % version_color st nv)
      (OpamPackage.Set.elements available)
  | All_versions ->
    let pkgs = OpamPackage.packages_of_name st.packages nv.name in
    OpamStd.List.concat_map "  " (fun nv ->
        OpamPackage.Version.to_string nv.version % version_color st nv)
      (OpamPackage.Set.elements pkgs)
  | Repository ->
    OpamRepositoryState.find_package_opt st.switch_repos
      (OpamSwitchState.repos_list st) nv |>
    OpamStd.Option.to_string (fun (r, _) -> OpamRepositoryName.to_string r)
  | Installed_files ->
    let changes_f =
      OpamPath.Switch.changes st.switch_global.root st.switch nv.name
    in
    (match OpamFile.Changes.read_opt changes_f with
     | None -> "n/a"
     | Some c ->
       OpamStd.Format.itemize ~bullet:""
         (fun (file, status) ->
            OpamFilename.to_string file ^ match status with
            | `Unchanged -> ""
            | `Removed -> " (absent)" % [`red]
            | `Changed -> " (modified since)" % [`yellow])
         (OpamDirTrack.check
            (OpamPath.Switch.root st.switch_global.root st.switch)
            c))

let display
    st ~header ~format ~dependency_order ~all_versions ?wrap ?(separator=" ")
    ?prettify ?normalise ?order packages =
  let packages =
    if all_versions then packages else
      OpamPackage.Name.Set.fold (fun name ->
          let pkgs = OpamPackage.packages_of_name packages name in
          let nv =
            let get = OpamPackage.Set.max_elt in
            try get (pkgs %% st.installed) with Not_found ->
            try get (pkgs %% st.pinned) with Not_found ->
            try get (pkgs %% Lazy.force st.available_packages) with Not_found ->
              get pkgs
          in
          OpamPackage.Set.add nv)
        (OpamPackage.names_of_packages packages)
        OpamPackage.Set.empty
  in
  let packages =
    if dependency_order then
      let universe =
        OpamSwitchState.universe st
          ~requested:(OpamPackage.names_of_packages packages)
          Depends
      in
      let deps_packages =
        OpamSolver.dependencies
          ~depopts:true ~installed:false ~unavailable:true ~build:true
          universe packages
      in
      List.filter (fun nv -> OpamPackage.Set.mem nv packages) deps_packages |>
      List.rev
    else match order with
      | None -> OpamPackage.Set.elements packages
      | Some o -> List.sort o (OpamPackage.Set.elements packages)
  in
  let add_head l =
    if header then
      (List.map (fun f -> "# "^disp_header f) format)
      :: l
    else l
  in
  if packages = [] then
    OpamConsole.msg "%s\n" (OpamConsole.colorise `red "# No matches found")
  else
    List.rev_map
      (fun nv -> List.map (detail_printer ?prettify ?normalise st nv) format)
      packages |>
    List.rev |>
    add_head |>
    OpamStd.Format.align_table |>
    OpamStd.Format.print_table ?cut:wrap stdout ~sep:separator

let get_switch_state gt =
  let rt = OpamRepositoryState.load `Lock_none gt in
  match OpamStateConfig.(!r.current_switch) with
  | None -> OpamSwitchState.load_virtual gt rt
  | Some sw -> OpamSwitchState.load `Lock_none gt rt sw

let print_depexts st packages tags_list =
  let required_tags = OpamStd.String.Set.of_list tags_list in
  OpamPackage.Name.Set.fold
    (fun name acc ->
       let nv = OpamSwitchState.get_package st name in
       let nv =
         if OpamPackage.Set.mem nv packages then nv else
           OpamPackage.Set.max_elt (OpamPackage.packages_of_name packages name)
       in
       let opam = get_opam st nv in
       match OpamFile.OPAM.depexts opam with
       | None -> acc
       | Some tags ->
         OpamStd.String.SetMap.fold (fun tags values acc ->
             if tags_list = [] then
               let line =
                 Printf.sprintf "%s: %s"
                   (String.concat " " (OpamStd.String.Set.elements tags))
                   (String.concat " " (OpamStd.String.Set.elements values))
               in
               OpamStd.String.Set.add line acc
             else if OpamStd.String.Set.for_all
                 (fun tag -> OpamStd.String.Set.mem tag required_tags)
                 tags
             then OpamStd.String.Set.union acc values
             else acc)
           tags acc)
    (OpamPackage.names_of_packages packages)
    OpamStd.String.Set.empty
  |> OpamStd.String.Set.iter print_endline

let list gt
    ~print_short ~filter:filter_arg ~order ~exact_name ~case_sensitive
    ?depends
    ?(reverse_depends=false) ?(recursive_depends=false) ?(resolve_depends=false)
    ?(depopts=false) ?depexts ?(dev=false)
    patterns
  =
  let module F = OpamFormula in
  let filter_f =
    match filter_arg with
    | `all -> F.Atom Any
    | `installed -> F.Atom Installed
    | `roots -> F.Atom Root
    | `installable -> F.Atom Available (* /!\ *)
  in
  let st = get_switch_state gt in
  let filter_deps =
    match depends with
    | None | Some [] -> F.Empty
    | Some deps ->
      let tog = {
        recursive = recursive_depends;
        depopts;
        build=true;
        test=false;
        doc=false;
        dev
      } in
      let deps =
        List.map (function
            | name, None ->
              (try
                 name, Some (`Eq, (OpamSwitchState.get_package st name).version)
               with Not_found -> name, None)
            | at -> at)
          deps
      in
      let atom =
        if resolve_depends then Solution (tog, deps)
        else if reverse_depends
        then Depends_on (tog, deps)
        else Required_by (tog, deps)
      in
      if depexts <> None then
        F.ors [F.Atom atom; F.Atom (Atoms deps)]
      else F.Atom atom
  in
  let patt_f =
    F.ors @@
    List.map (fun pat ->
        F.Atom (Pattern ({case_sensitive; exact = exact_name;
                          fields =
                            if exact_name then ["name"]
                            else ["name"; "descr"; "tags"];
                          glob = true;
                          ext_fields = false}, pat)))
      patterns
  in
  let formula = F.ands [filter_f; filter_deps; patt_f] in
  log "Package selector: %a" (slog string_of_formula) formula;
  if not print_short && formula <> OpamFormula.Empty then
    OpamConsole.msg "# Packages matching: %s\n" (string_of_formula formula);
  let packages = filter ~base:(st.packages ++ st.installed) st formula in
  if OpamPackage.Set.is_empty packages then
    (if not print_short then OpamConsole.error "No matches";
     OpamStd.Sys.exit 1);
  let format = if print_short then [Name] else default_list_format in
  match depexts with
  | None ->
    display st ~format ~dependency_order:(order=`depends)
      ~header:(not print_short) ~all_versions:false packages
  | Some tags_list ->
    print_depexts st packages tags_list

let info gt ~fields ~raw_opam ~where ?normalise ?(show_empty=false) atoms =
  let st = get_switch_state gt in
  let packages =
    OpamFormula.packages_of_atoms (st.packages ++ st.installed) atoms
  in
  if OpamPackage.Set.is_empty packages then
    (OpamConsole.error "No package matching %s found"
       (OpamStd.List.concat_map " or " OpamFormula.short_string_of_atom atoms);
     OpamStd.Sys.exit 1);
  let fields = List.map field_of_string fields in
  let all_versions_fields = [
    Name;
    All_installed_versions;
    All_versions;
  ] in
  let one_version_fields = [
    Version;
    Repository;
    Pinning_target;
    Field "url.src";
    Field "url.checksum";
    Field "homepage";
    Field "bug-reports";
    Field "dev-repo";
    Field "authors";
    Field "license";
    Field "tags";
    Field "flags";
    Field "depends";
    Field "depopts";
    Synopsis;
    Description;
  ] in
  let output_table fields nv =
    let tbl =
      List.fold_left (fun acc item ->
          let contents = detail_printer ?normalise st nv item in
          if show_empty || contents <> "" then
            [ OpamConsole.colorise `blue (string_of_field item); contents ]
            :: acc
          else acc)
        [] (List.rev fields)
    in
    OpamStd.Format.align_table tbl |>
    OpamStd.Format.print_table stdout ~sep:" ";
  in
  OpamPackage.names_of_packages packages |>
  OpamPackage.Name.Set.iter (fun name ->
      let nvs = OpamPackage.packages_of_name packages name in
      let choose =
        try OpamPackage.Set.choose (nvs %% st.pinned) with Not_found ->
        try OpamPackage.Set.choose (nvs %% st.installed) with Not_found ->
        try OpamPackage.Set.max_elt (nvs %% Lazy.force st.available_packages)
        with Not_found ->
          OpamPackage.Set.max_elt nvs
      in
      let opam = get_opam st choose in
      if where then
        OpamConsole.msg "%s\n"
          (match OpamFile.OPAM.metadata_dir opam with
           | Some dir ->
             OpamFilename.Dir.to_string OpamFilename.Op.(dir / "opam")
           | None -> "<nowhere>")
      else if raw_opam then
        OpamFile.OPAM.write_to_channel stdout opam
      else
      match fields with
      | [] ->
        OpamConsole.header_msg "%s: information on all versions"
          (OpamPackage.Name.to_string choose.name);
        output_table all_versions_fields choose;
        OpamConsole.header_msg "Version-specific details";
        output_table one_version_fields choose
      | [f] -> OpamConsole.msg "%s" (detail_printer ?normalise st choose f)
      | fields -> output_table fields choose
    )
