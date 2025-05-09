open Unix
open Util
open Ast
open Lexer
open Parser
open Verifast0
open Verifast
open GMain
open Shape_analysis_frontend
open Vfconfig
open Linemarks
open Branch_png

let () = Register_provers.register_provers ()

type vfide_rc_file = {
  settings: (string * string) list;
  sections: (string * string list) list;
}

let read_rc_file path =
  let ch = open_in path in
  Fun.protect ~finally:(fun () -> close_in ch) begin fun () ->
    let rec parse_section_header lineno settings sections line =
      if not (String.ends_with ~suffix:"]" line) then failwith (Printf.sprintf "%s: line %d: ] expected at end of line" path lineno);
      let section_key = String.sub line 1 (String.length line - 2) in
      parse_section lineno settings sections section_key []
    and parse_section lineno settings sections section_key section_lines =
      match input_line ch with
        exception End_of_file -> { settings = List.rev settings; sections = List.rev ((section_key, List.rev section_lines)::sections) }
      | line ->
        let line = String.trim line in
        if line = "" || String.starts_with ~prefix:"#" line then
          parse_section (lineno + 1) settings sections section_key section_lines
        else if String.starts_with ~prefix:"[" line then
          parse_section_header lineno settings ((section_key, List.rev section_lines)::sections) line
        else
          parse_section (lineno + 1) settings sections section_key (line::section_lines)
    in
    let rec parse_settings lineno settings =
      match input_line ch with
        exception End_of_file -> { settings = List.rev settings; sections = [] }
      | line ->
        let line = String.trim line in
        if line = "" || String.starts_with ~prefix:"#" line then
          parse_settings (lineno + 1) settings
        else if String.starts_with ~prefix:"[" line then
          parse_section_header lineno settings [] line
        else
          match String.index line '=' with
            exception Not_found -> failwith (Printf.sprintf "%s: line %d: = expected in line" path lineno)
          | index ->
            let key = String.sub line 0 index in
            let value = String.sub line (index + 1) (String.length line - index - 1) in
            parse_settings (lineno + 1) ((key, value)::settings)
    in
    parse_settings 1 []
  end

let write_rc_file path {settings; sections} =
  let ch = open_out path in
  Fun.protect ~finally:(fun () -> close_out ch) begin fun () ->
    List.iter (fun (key, value) -> Printf.fprintf ch "%s=%s\n" key value) settings;
    sections |> List.iter begin fun (section_key, section_lines) ->
      Printf.fprintf ch "\n[%s]\n" section_key;
      List.iter (fun line -> Printf.fprintf ch "%s\n" line) section_lines;
    end
  end

let vfiderc_path =
  Option.map
    (fun homepath -> Filename.concat homepath ".vfiderc")
    (Sys.getenv_opt (match platform with Windows -> "LOCALAPPDATA" | _ -> "HOME"))

type vfiderc_info = {
  max_recent_files: int;
  max_recent_folders: int;
  recent_files: string list;
  recent_folders: string list;
  other_settings: (string * string) list;
  other_sections: (string * string list) list;
}

let load_vfiderc () =
  let {settings; sections} =
    match vfiderc_path with
    | Some vfiderc_path when Sys.file_exists vfiderc_path ->
      read_rc_file vfiderc_path
    | _ -> {settings = []; sections = []}
  in
  let max_recent_files_opt, settings = Util.remove_assoc_opt "max_recent_files" settings in
  let max_recent_folders_opt, settings = Util.remove_assoc_opt "max_recent_folders" settings in
  let recent_files_opt, sections = Util.remove_assoc_opt "recent_files" sections in
  let recent_folders_opt, sections = Util.remove_assoc_opt "recent_folders" sections in
    {
      max_recent_files =
        Option.value ~default:20 (Option.bind max_recent_files_opt int_of_string_opt);
      max_recent_folders =
        Option.value ~default:20 (Option.bind max_recent_folders_opt int_of_string_opt);
      recent_files =
        Option.value ~default:[] recent_files_opt;
      recent_folders =
        Option.value ~default:[] recent_folders_opt;
      other_settings = settings;
      other_sections = sections;
    }

(* Called whenever a file is opened or saved *)
let register_recent_file path =
  match vfiderc_path with
    None -> () (* Don't store any persistent state *)
  | Some vfiderc_path ->
    let {max_recent_files; max_recent_folders; recent_files; recent_folders; other_settings; other_sections} = load_vfiderc () in
    let recent_file = Util.abs_path path in
    let recent_files' = Util.take max_recent_files (recent_file::List.filter (fun p -> p <> recent_file) recent_files) in
    let recent_folder = Filename.dirname recent_file in
    let recent_folders' = Util.take max_recent_folders (recent_folder::List.filter (fun p -> p <> recent_folder) recent_folders) in
    if (recent_files', recent_folders') <> (recent_files, recent_folders) then 
      write_rc_file vfiderc_path {
        settings = [
          "max_recent_files", string_of_int max_recent_files;
          "max_recent_folders", string_of_int max_recent_folders;
        ] @ other_settings;
        sections = [
          "recent_files", recent_files';
          "recent_folders", recent_folders';
        ] @ other_sections;
      }

type layout = FourThree | Widescreen

let include_paths: string list ref = ref []
let define_macros: string list ref = ref []

let () = Unix.putenv "LANG" "en_US" (* This works around a problem that causes vfide to become unusable in the Chinese locale. *)

let () =
  if platform = Linux && Sys.getenv_opt "VERIFAST_USE_PLATFORM_GTK_THEME" = None then
    Unix.putenv "GTK_DATA_PREFIX" "bogus dir" (* See https://github.com/verifast/verifast/issues/147 *)

(* The lablgtk.init has a problem that automatically finding
 * this package does not always work. To avoid that problem,
 * we just do what this package do: calling GTKMain.Main.init().
 * Sources: https://forge.ocamlcore.org/tracker/?func=detail&atid=1032&aid=1059&group_id=220
 *          http://permalink.gmane.org/gmane.comp.lang.ocaml.lib.gtk/1464
 *)
let _ = GtkMain.Main.init ~setlocale:false ()

let normalize_to_lf text =
  let n = String.length text in
  let buffer = Buffer.create n in
  let rec iter lfCount crCount crlfCount k =
    if k = n then begin
      let counts = [lfCount, platform = Linux || platform = MacOS, "\n"; crlfCount, platform = Windows, "\r\n"; crCount, false, "\r"] in
      let eol =
        match List.sort (fun x y -> - compare x y) counts with
        | (_, _, eol)::_ -> eol
        | _ -> assert false
      in
      (eol, Buffer.contents buffer)
    end else
      let c = text.[k] in
      match c with
      | '\n' ->
        Buffer.add_char buffer c; iter (lfCount + 1) crCount crlfCount (k + 1)
      | '\r' ->
        if k + 1 < n && text.[k + 1] = '\n' then begin
          Buffer.add_char buffer '\n'; iter lfCount crCount (crlfCount + 1) (k + 2)
        end else begin
          Buffer.add_char buffer '\n'; iter lfCount (crCount + 1) crlfCount (k + 1)
        end
      | c ->
        Buffer.add_char buffer c; iter lfCount crCount crlfCount (k + 1)
  in
  iter 0 0 0 0

let convert_eol eol text =
  let n = String.length text in
  let buffer = Buffer.create n in
  let rec iter k =
    if k = n then
      Buffer.contents buffer
    else
      match text.[k] with
      | '\n' ->
        Buffer.add_string buffer eol; iter (k + 1)
      | '\r' ->
        if k + 1 < n && text.[k + 1] = '\n' then begin
          Buffer.add_string buffer eol; iter (k + 2)
        end else begin
          Buffer.add_string buffer eol; iter (k + 1)
        end
      | c ->
        Buffer.add_char buffer c; iter (k + 1)
  in
  iter 0

type undo_action =
  Insert of int * string
| Delete of int * string

let index_of_byref x xs =
  let rec iter k xs =
    match xs with
      [] -> raise Not_found
    | x0::xs -> if x0 == x then k else iter (k + 1) xs
  in
  iter 0 xs
  
let string_of_process_status s =
  match s with
    Unix.WEXITED n -> Printf.sprintf "WEXITED %d" n
  | Unix.WSIGNALED n -> Printf.sprintf "WSIGNALED %d" n
  | Unix.WSTOPPED n -> Printf.sprintf "WSTOPPED %d" n
  
let sys cmd =
  let chan = Unix.open_process_in cmd in
  let line = input_line chan in
  let exitStatus = Unix.close_process_in chan in
  if exitStatus <> Unix.WEXITED 0 then failwith (Printf.sprintf "Command '%s' failed with exit status %s" cmd (string_of_process_status exitStatus));
  line

let string_of_time time =
  let tm = Unix.gmtime time in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d%9f" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday tm.tm_hour tm.tm_min tm.tm_sec (fst (modf time))

let path_last_modification_time path =
  (Unix.stat path).st_mtime

let file_has_changed path mtime =
  try
    let mtime' = path_last_modification_time path in
    let result = mtime' <> mtime in
    if result then begin
      Printf.printf "File '%s' was last read by vfide at '%s' but was modified by another process at '%s'.\n"
        path (string_of_time mtime) (string_of_time mtime');
      flush Stdlib.stdout
    end;
    result
  with Unix.Unix_error (_, _, _) -> true

let in_channel_last_modification_time chan =
  (Unix.fstat (Unix.descr_of_in_channel chan)).st_mtime

let out_channel_last_modification_time chan =
  (Unix.fstat (Unix.descr_of_out_channel chan)).st_mtime

type tree_node = TreeNode of node_type * int * int * tree_node list

module TreeMetrics = struct
  let dotWidth = 15
  let dotRadius = dotWidth / 2
  let padding = 4
  let cw = dotWidth + 2 * padding
end

let show_ide initialPath prover codeFont traceFont vfbindings layout javaFrontend enforceAnnotations verifyAndQuit =
  let vfbindings = ref vfbindings in
  let set_or_reset_bool_vfbinding p b = vfbindings := Vfbindings.set_or_reset_bool p b !vfbindings in
  let leftBranchPixbuf = Branchleft_png.pixbuf () in
  let rightBranchPixbuf = Branchright_png.pixbuf () in
  let ctxts_lifo = ref None in
  let msg = ref None in
  let url = ref None in
  let appTitle = "VeriFast" ^ string_of_string_opt Verifast.version ^ " IDE" in
  let root = GWindow.window
    ~title:appTitle ()
  in
  let fontScalePower = ref 0 in
  let getScaledFont fontName =
    if !fontScalePower = 0 then fontName else
    let fontDescription = new GPango.font_description (GPango.font_description fontName) in
    let size = float_of_int fontDescription#size in
    let size = size *. (1.3 ** float_of_int !fontScalePower) in
    let size = int_of_float size in
    fontDescription#modify ~size ();
    fontDescription#to_string
  in
  let codeFont = ref codeFont in
  let scaledCodeFont = ref !codeFont in
  let traceFont = ref traceFont in
  let scaledTraceFont = ref !traceFont in
  let actionGroup = GAction.action_group ~name:"Actions" () in
  let useJavaFrontend = ref false in
  let toggle_java_frontend active =
    (useJavaFrontend := active;
    if !useJavaFrontend then
      Java_frontend_bridge.load()
    else
      Java_frontend_bridge.unload())
  in
  let current_tab = ref None in
  let showLineNumbers enable =
    match !current_tab with
      None -> ()
    | Some tab ->
      tab#mainView#view#set_show_line_numbers enable;
      tab#subView#view#set_show_line_numbers enable
  in
  let showWhitespace enable =
    match !current_tab with
      None -> ()
    | Some tab ->
      let flags = if enable then [`SPACE; `TAB] else [] in
      tab#mainView#view#set_draw_spaces flags;
      tab#subView#view#set_draw_spaces flags
  in
  let showRightMargin enable =
    match !current_tab with
      None -> ()
    | Some tab ->
      tab#mainView#view#set_show_right_margin enable;
      tab#subView#view#set_show_right_margin enable
  in
  let showLineNumbersAction =
    let a = GAction.toggle_action ~name:"ShowLineNumbers" () in
    a#set_label "Show _line numbers"; ignore $. a#connect#toggled ~callback:(fun () -> showLineNumbers a#get_active);
    a
  in
  let showWhitespaceAction =
    let a = GAction.toggle_action ~name:"ShowWhitespace" () in
    a#set_label "Show _whitespace"; ignore $. a#connect#toggled ~callback:(fun () -> showWhitespace a#get_active);
    a
  in
  let showRightMarginAction =
    let a = GAction.toggle_action ~name:"ShowRightMargin" () in
    a#set_label "Show _right margin ruler"; ignore $. a#connect#toggled ~callback:(fun () -> showRightMargin a#get_active);
    a
  in
  let launch_browser url =
    match platform with
      MacOS -> ignore $. Sys.command ("open '" ^ url ^ "'")
    | Linux -> ignore $. Sys.command ("xdg-open '" ^ url ^ "'")
    | Windows ->
      (* The below command asynchronously launches a "cmd" process that launches the help topic.
         Launching the help topic synchronously seems to cause vfide to hang for between 6 and 30 seconds.
         My hypothesis is that "cmd /C start xyz.html" performs a DDE broadcast to all windows on the desktop,
         which apparently blocks until a timeout happens if some window is not responding. If the
         Help topic is launched synchronously inside the GUI event handler thread, the vfide window is not
         responsive until the Help topic is launched. Ergo the deadlock.
         This seems to be confirmed here <http://wiki.tcl.tk/996> and here <http://blogs.msdn.com/b/oldnewthing/archive/2007/02/26/1763683.aspx>.
      *)
      ignore $. Unix.create_process "cmd" [| "/C"; "start"; "Dummy Title"; url |] Unix.stdin Unix.stdout Unix.stderr
  in
  let showBannerDialog () =
    let dialog = GWindow.dialog ~title:"About VeriFast" ~parent:root () in
    dialog#action_area#set_border_width 0;
    let vbox = dialog#vbox in
    ignore $. GMisc.label ~xpad:2 ~ypad:2 ~line_wrap:true ~text:(Verifast.banner ()) ~packing:vbox#pack ();
    ignore $. (GButton.button ~stock:`OK ~packing:dialog#action_area#add ())#connect#clicked ~callback:(fun () ->
      dialog#response `DELETE_EVENT
    );
    ignore $. (GButton.button ~label:"Launch Homepage" ~packing:dialog#action_area#add ())#connect#clicked ~callback:(fun () ->
      launch_browser "https://github.com/verifast/verifast/"
    );
    ignore $. (GButton.button ~label:"Show Contributors" ~packing:dialog#action_area#add ())#connect#clicked ~callback:(fun () ->
      launch_browser "https://github.com/verifast/verifast/graphs/contributors"
    );
    ignore $. dialog#run();
    dialog#destroy()
  in
  let _ =
    let a = GAction.add_action in
    GAction.add_actions actionGroup [
      a "File" ~label:"_File";
      a "New" ~stock:`NEW;
      a "Open" ~stock:`OPEN;
      a "Save" ~stock:`SAVE ~accel:"<control>S" ~tooltip:"Save";
      a "SaveAs" ~label:"Save _as";
      a "Close" ~stock:`CLOSE ~tooltip:"Close";
      a "Edit" ~label:"_Edit";
      a "Undo" ~stock:`UNDO ~accel:"<Ctrl>Z";
      a "Redo" ~stock:`REDO ~accel:"<Ctrl>Y";
      a "Preferences" ~label:"_Preferences...";
      a "View" ~label:"Vie_w";
      a "ClearTrace" ~label:"_Clear trace" ~accel:"<Ctrl>L";
      a "TextSize" ~label:"_Text size";
      a "TextLarger" ~label:"_Larger" ~accel:"<Alt>Up";
      a "TextSmaller" ~label:"_Smaller" ~accel:"<Alt>Down";
      a "TextSizeDefault" ~label:"_Default";
      (fun group -> group#add_action showLineNumbersAction);
      (fun group -> group#add_action showWhitespaceAction);
      (fun group -> group#add_action showRightMarginAction);
      a "ShowExecutionTree" ~label:"Show _execution tree" ~accel:"<Ctrl>T";
      a "Verify" ~label:"_Verify";
      GAction.add_toggle_action "CheckOverflow" ~label:"Check arithmetic overflow" ~active:(not (Vfbindings.get Vfparam_disable_overflow_check !vfbindings)) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_disable_overflow_check (not toggleAction#get_active));
      GAction.add_toggle_action "AllowTruncatingSignedArithmetic" ~label:"Allow truncating signed integer arithmetic (GCC's -fwrapv)" ~active:(Vfbindings.get Vfparam_fwrapv !vfbindings) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_fwrapv toggleAction#get_active);
      GAction.add_toggle_action "AssumeLeftToRightEvaluation" ~label:"Assume left-to-right evaluation" ~active:(Vfbindings.get Vfparam_assume_left_to_right_evaluation !vfbindings) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_assume_left_to_right_evaluation toggleAction#get_active);
      GAction.add_toggle_action "AssumeNoProvenance" ~label:"Assume no pointer provenance" ~active:(Vfbindings.get Vfparam_assume_no_provenance !vfbindings) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_assume_no_provenance toggleAction#get_active);
      GAction.add_toggle_action "AssumeNoSubobjectProvenance" ~label:"Assume no subobject provenance" ~active:(Vfbindings.get Vfparam_assume_no_subobject_provenance !vfbindings) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_assume_no_subobject_provenance toggleAction#get_active);
      GAction.add_toggle_action "NoStrictAliasing" ~label:"Assume untyped memory (GCC's fno-strict-aliasing)" ~active:(Vfbindings.get Vfparam_fno_strict_aliasing !vfbindings) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_fno_strict_aliasing toggleAction#get_active);
      GAction.add_toggle_action "IgnoreRefCreation" ~label:"Treat Rust reference creation like raw pointer creation" ~active:(Vfbindings.get Vfparam_ignore_ref_creation !vfbindings) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_ignore_ref_creation toggleAction#get_active);
      GAction.add_toggle_action "IgnoreUnwindPaths" ~label:"Ignore Rust unwind paths" ~active:(Vfbindings.get Vfparam_ignore_unwind_paths !vfbindings) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_ignore_unwind_paths toggleAction#get_active);
      GAction.add_toggle_action "UseJavaFrontend" ~label:"Use the Java frontend" ~active:(toggle_java_frontend javaFrontend; javaFrontend) ~callback:(fun toggleAction -> toggle_java_frontend toggleAction#get_active);
      GAction.add_toggle_action "SimplifyTerms" ~label:"Simplify Terms" ~active:(not (Vfbindings.get Vfparam_no_simplify_terms !vfbindings)) ~callback:(fun toggleAction -> set_or_reset_bool_vfbinding Vfparam_no_simplify_terms (not toggleAction#get_active));
      a "Include paths" ~label:"_Include paths...";
      a "Find file (top window)" ~label:"Find file (_top window)..." ~stock:`FIND ~accel:"<Shift>F7";
      a "Find file (bottom window)" ~label:"Find _file (bottom window)..." ~stock:`FIND ~accel:"F7";
      a "VerifyProgram" ~label:"Verify program" ~stock:`MEDIA_PLAY ~accel:"F5" ~tooltip:"Verify";
      a "VerifyFunction" ~label:"Verify function" ~stock:`EXECUTE ~accel:"<Shift>F5" ~tooltip:"Verify function";
      a "RunToCursor" ~label:"_Run to cursor" ~stock:`JUMP_TO ~accel:"<Ctrl>F5" ~tooltip:"Run to cursor";
      a "RunShapeAnalysis" ~label:"Run shape analysis on function" ~stock:`MEDIA_FORWARD ~accel:"F9" ~tooltip:"Run shape analysis on the function where the cursor is in";
      a "TopWindow" ~label:"Window(_Top)";
      a "BottomWindow" ~label:"Window(_Bottom)";
      a "TargetArchitecture" ~label:"_Target architecture";
      a "OpenRecent" ~label:"Open _Recent";
      a "Stub";
      a "Help" ~label:"_Help";
      a "About" ~stock:`ABOUT ~callback:(fun _ -> showBannerDialog ())
    ]
  in
  let ui = GAction.ui_manager() in
  ui#insert_action_group actionGroup 0;
  root#add_accel_group ui#get_accel_group;
  ignore (ui#add_ui_from_string "
    <ui>
      <menubar name='MenuBar'>
        <menu action='File'>
          <menuitem action='New' />
          <menuitem action='Open' />
          <menu action='OpenRecent'>
            <menuitem action='Stub' />
          </menu>
          <menuitem action='Save' />
          <menuitem action='SaveAs' />
          <menuitem action='Close' />
        </menu>
        <menu action='Edit'>
          <menuitem action='Undo' />
          <menuitem action='Redo' />
          <separator />
          <menuitem action='Preferences' />
        </menu>
        <menu action='View'>
          <menuitem action='ClearTrace' />
          <separator />
          <menu action='TextSize'>
            <menuitem action='TextLarger' />
            <menuitem action='TextSmaller' />
            <separator />
            <menuitem action='TextSizeDefault' />
          </menu>
          <separator />
          <menuitem action='ShowLineNumbers' />
          <menuitem action='ShowWhitespace' />
          <menuitem action='ShowRightMargin' />
          <menuitem action='Find file (top window)' />
          <menuitem action='Find file (bottom window)' />
          <separator />
          <menuitem action='ShowExecutionTree' />
        </menu>
        <menu action='Verify'>
          <menuitem action='VerifyProgram' />
          <menuitem action='VerifyFunction' />
          <menuitem action='RunToCursor' />
          <separator />
          <menuitem action='RunShapeAnalysis' />
          <separator />
          <menuitem action='CheckOverflow' />
          <menuitem action='AllowTruncatingSignedArithmetic' />
          <menuitem action='AssumeLeftToRightEvaluation' />
          <menuitem action='AssumeNoProvenance' />
          <menuitem action='AssumeNoSubobjectProvenance' />
          <menuitem action='NoStrictAliasing' />
          <separator />
          <menuitem action='IgnoreRefCreation' />
          <menuitem action='IgnoreUnwindPaths' />
          <separator />
          <menu action='TargetArchitecture'>
            <menuitem action='Stub' />
          </menu>
          <separator />
          <menuitem action='UseJavaFrontend' />
          <menuitem action='SimplifyTerms' />
          <menuitem action='Include paths' />
        </menu>
        <menu action='TopWindow'>
           <menuitem action='Stub' />
        </menu>
        <menu action='BottomWindow'>
           <menuitem action='Stub' />
        </menu>
        <menu action='Help'>
          <menuitem action='About'/>
        </menu>
      </menubar>
      <toolbar name='ToolBar'>
        <toolitem action='Save' />
        <toolitem action='Close' />
        <separator />
        <toolitem action='Undo' />
        <toolitem action='Redo' />
        <separator />
        <toolitem action='VerifyProgram' />
        <toolitem action='VerifyFunction' />
        <toolitem action='RunToCursor' />
      </toolbar>
    </ui>
  ");
  let undoAction = actionGroup#get_action "Undo" in
  let redoAction = actionGroup#get_action "Redo" in
  let windowMenuItemTop = new GMenu.menu_item (GtkMenu.MenuItem.cast (ui#get_widget "/MenuBar/TopWindow")#as_widget) in
  let windowMenuItemBottom = new GMenu.menu_item (GtkMenu.MenuItem.cast (ui#get_widget "/MenuBar/BottomWindow")#as_widget) in
  let openRecentMenuItem = new GMenu.menu_item (GtkMenu.MenuItem.cast (ui#get_widget "/MenuBar/File/OpenRecent")#as_widget) in
  let targetMenuItem = new GMenu.menu_item (GtkMenu.MenuItem.cast (ui#get_widget "/MenuBar/Verify/TargetArchitecture")#as_widget) in
  let ignore_text_changes = ref false in
  let rootVbox = GPack.vbox ~packing:root#add () in
  root#resize
    ~width:(match layout with FourThree -> 800 | Widescreen -> 1024)
    ~height:(match layout with FourThree -> 600 | Widescreen -> 640);
  rootVbox#pack (ui#get_widget "/MenuBar");
  let toolbar = new GButton.toolbar (GtkButton.Toolbar.cast (ui#get_widget "/ToolBar")#as_widget) in
  toolbar#set_icon_size `SMALL_TOOLBAR;
  toolbar#set_style `ICONS;
  let separatorToolItem = GButton.separator_tool_item () in
  toolbar#insert separatorToolItem;
  let messageToolItem = GButton.tool_item ~expand:true () in
  let messageHBox = GPack.hbox ~packing:(messageToolItem#add) () in
  messageToolItem#set_border_width 3;
  let messageEntry = GEdit.entry ~show:false ~editable:false ~has_frame:false ~packing:(messageHBox#add) () in
  let messageEntryCheckDone = ref false in
  messageEntry#coerce#misc#modify_font_by_name !scaledTraceFont;
  let helpButton = GButton.button ~show:false ~label:" ? " ~packing:(messageHBox#pack) () in
  let show_help url =
    launch_browser (!bindir ^ "/../help/" ^ url ^ ".html")
  in
  ignore (helpButton#connect#clicked ~callback:(fun () -> (match (parse_error_attributes !url).help_topic with None -> () | Some url  -> show_help url);));
  let fixButton = GButton.button ~show:false ~label:"Fix" ~packing:(messageHBox#pack) () in
  toolbar#insert messageToolItem;
  rootVbox#pack (toolbar#coerce);
  let treeSeparator = GPack.paned `HORIZONTAL ~packing:(rootVbox#pack ~expand:true) () in
  let treeVbox = GPack.vbox ~packing:(treeSeparator#pack2 ~shrink:true) () in
  let (treeCombo, (treeComboListStore, treeComboColumn)) as treeComboText = GEdit.combo_box_text
    ~packing:treeVbox#pack
    ()
  in
  let treeScroll = GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN ~packing:(treeVbox#pack ~expand:true) () in
  let treeDrawingArea = GMisc.drawing_area ~packing:treeScroll#add_with_viewport () in
  treeSeparator#set_position (match layout with FourThree -> 800 | Widescreen -> 1024);
  let executionForest = ref [] in
  let reportExecutionForest forest =
    let rec findFork (Node (nodeType, ns) as n) =
      match !ns with
        [Node (ExecNode _, _) as n] -> findFork n
      | [n] when nodeType = BranchNode -> findFork n
      | _ -> n
    in
    let rec convert forest =
      forest |> List.rev |> List.map begin fun (Node (nodeType, ns)) ->
        let ns = convert (List.map findFork !ns) in
        let width =
          ns
            |> List.map (fun (TreeNode (_, width, _, _)) -> width)
            |> List.fold_left (+) 0
            |> max 1
        in
        let height =
          ns
            |> List.map (fun (TreeNode (_, width, height, _)) -> height)
            |> List.fold_left max 0
        in
        TreeNode (nodeType, width, height + 1, ns)
      end
    in
    executionForest := convert forest;
    treeComboListStore#clear ();
    !executionForest |> List.iter (fun (TreeNode (ExecNode (msg, _), _, _, _)) -> GEdit.text_combo_add treeComboText msg)
  in
  ignore $. treeCombo#connect#changed ~callback:begin fun () ->
    let active = treeCombo#active in
    if 0 <= active then begin
      let TreeNode (_, w, h, ns) = List.nth !executionForest active in
      let open TreeMetrics in
      treeDrawingArea#set_size ~width:(cw * w) ~height:(cw * h)
    end;
    treeDrawingArea#misc#draw None
  end;
  let rootTable = GPack.paned (match layout with FourThree -> `VERTICAL | Widescreen -> `HORIZONTAL) ~border_width:3 ~packing:(treeSeparator#pack1) () in
  rootTable#set_position (match layout with FourThree -> 400 | Widescreen -> 200);
  let textPaned = GPack.paned `VERTICAL () in
  begin match layout with
  | FourThree  -> rootTable#pack1 ~resize:true ~shrink:true textPaned#coerce
  | Widescreen -> rootTable#pack2 ~resize:true ~shrink:true textPaned#coerce
  end;
  textPaned#set_position 0;
  let srcPaned = GPack.paned `HORIZONTAL ~packing:(textPaned#pack2 ~resize:true ~shrink:true) () in
  let subPaned = GPack.paned `HORIZONTAL ~packing:(textPaned#pack1 ~resize:true ~shrink:true) () in
  begin match layout with
  | FourThree  ->
    srcPaned#set_position 650;
    subPaned#set_position 650
  | Widescreen ->
    srcPaned#set_position 674;
    subPaned#set_position 674
  end;
  let textNotebook = GPack.notebook ~scrollable:true ~packing:(srcPaned#pack1 ~resize:true ~shrink:true) () in
  let subNotebook = GPack.notebook ~scrollable:true ~packing:(subPaned#pack1 ~resize:true ~shrink:true) () in
  let buffers = ref [] in
  let goto_tab tab notebook =
    notebook#goto_page (index_of_byref tab !buffers)
  in
  let getTitleOfTab tab =
    match !(tab#path) with
      None -> "(Untitled)"
    | Some (path, mtime) -> path
  in
  let updateWindowTitle (): unit =
    let filename = 
      match !buffers with
        [] -> "(no file)"
      | tab::tabs -> getTitleOfTab tab
    in
    root#set_title (filename ^ " - " ^ appTitle)
  in
  let updateBufferMenu () =
    let menu notebook = 
      let gtk_menu = GMenu.menu () in
      let items = !buffers |> List.map (fun tab -> getTitleOfTab tab, tab) in
      let items = List.sort (fun (name1, _) (name2, _) -> compare name1 name2) items in
      items |> List.iter begin fun (name, tab) ->
         let item = GMenu.menu_item ~label:name ~packing:gtk_menu#add () in
         ignore (item#connect#activate ~callback:(fun () -> goto_tab tab notebook))
      end;
      gtk_menu
    in
      windowMenuItemTop#set_submenu (menu subNotebook);
      windowMenuItemBottom#set_submenu (menu textNotebook)
  in
  let open_recent_folder_func = ref (fun _ -> ()) in
  let open_recent_file_func = ref (fun _ -> ()) in
  let updateOpenRecentMenu () =
    let {recent_files; recent_folders} = load_vfiderc () in
    let menu = GMenu.menu () in
    recent_folders |> List.iter begin fun recent_folder ->
      let item = GMenu.menu_item ~label:recent_folder ~packing:menu#add () in
      ignore @@ item#connect#activate ~callback:(fun () -> !open_recent_folder_func recent_folder)
    end;
    ignore (GMenu.separator_item ~packing:menu#add ());
    recent_files |> List.iter begin fun recent_file ->
      let item = GMenu.menu_item ~label:recent_file ~packing:menu#add () in
      ignore @@ item#connect#activate ~callback:(fun () -> !open_recent_file_func recent_file)
    end;
    openRecentMenuItem#set_submenu menu
  in
  let register_recent_file path =
    register_recent_file path;
    updateOpenRecentMenu ()
  in
  let targetMenu = GMenu.menu () in
  let targetMenuGroup = ref None in
  let targetMenuItems =
    data_models_ |> List.map begin fun (name, model) ->
      let {int_width; long_width; ptr_width} = model in
      let item = GMenu.radio_menu_item ~active:(Vfbindings.get Vfparam_data_model !vfbindings = Some model) ?group:!targetMenuGroup ~label:(Printf.sprintf "sizeof(int, long, void *) = %d, %d, %d - %s" (1 lsl int_width) (1 lsl long_width) (1 lsl ptr_width) name) ~packing:targetMenu#add () in
      targetMenuGroup := Some item#group;
      (Some model, item)
    end
  in
  let targetMenuItems =
    ignore (GMenu.separator_item ~packing:targetMenu#add ());
    let item = GMenu.radio_menu_item ~active:(Vfbindings.get Vfparam_data_model !vfbindings = None) ?group:!targetMenuGroup ~label:"All of the above" ~packing:targetMenu#add () in
    targetMenuItems @ [(None, item)]
  in
  targetMenuItem#set_submenu targetMenu;
  targetMenuItems |> List.iter (fun (model, item) -> ignore (item#connect#activate ~callback:(fun () -> vfbindings := Vfbindings.set Vfparam_data_model model !vfbindings)));
  let updateWhenTabListChanges () =
    updateBufferMenu ();
    updateWindowTitle ()
  in
  let updateBufferTitle tab =
    let text = (match !(tab#path) with None -> "(New buffer)" | Some (path, mtime) -> Filename.basename path) ^ (if tab#buffer#modified then "*" else "") in
    tab#mainView#label#set_text text;
    tab#subView#label#set_text text
  in
  let bufferChangeListener = ref (fun _ -> ()) in
  let set_current_tab tab =
    current_tab := tab;
    match tab with
      None ->
      undoAction#set_sensitive false;
      redoAction#set_sensitive false;
      showLineNumbersAction#set_sensitive false;
      showWhitespaceAction#set_sensitive false;
      showRightMarginAction#set_sensitive false
    | Some tab ->
      undoAction#set_sensitive (!(tab#undoList) <> []);
      redoAction#set_sensitive (!(tab#redoList) <> []);
      showLineNumbersAction#set_sensitive true;
      showLineNumbersAction#set_active (tab#mainView#view#show_line_numbers);
      showWhitespaceAction#set_sensitive true;
      showWhitespaceAction#set_active (tab#subView#view#draw_spaces <> []);
      showRightMarginAction#set_sensitive true;
      showRightMarginAction#set_active (tab#mainView#view#show_right_margin)
  in
  let tag_name_of_range_kind kind =
    match kind with
      KeywordRange -> "keyword"
    | GhostKeywordRange -> "ghostKeyword"
    | GhostRange -> "ghostRange"
    | GhostRangeDelimiter -> "ghostRangeDelimiter"
    | CommentRange -> "comment"
    | ErrorRange -> "error"
  in
  let srcpos_iter buffer (line, col) =
    (buffer#get_iter_at_byte ~line:(line - 1) 0)#set_line_index (col - 1) (* Hack, to work around an apparent Gtk or lablgtk bug *)
    (* buffer#get_iter (`LINEBYTE (line - 1, col - 1)) *)
  in
  (* let string_of_iter it = string_of_int it#line ^ ":" ^ string_of_int it#line_offset in *)
  let apply_tag_by_name tab tagName ~start ~stop =
    tab#apply_tag_enabled := true;
    (* to make error visible when start and stop are same location *)
    let start =
      if (start#offset = stop#offset && start#line = stop#line && start#offset > 0) then
        start#set_offset (start#offset - 1)
      else
        start
    in
    tab#buffer#apply_tag_by_name tagName ~start ~stop;
    tab#apply_tag_enabled := false
  in
  let apply_tag tab tag ~start ~stop =
    tab#apply_tag_enabled := true;
    tab#buffer#apply_tag tag ~start ~stop;
    tab#apply_tag_enabled := false
  in
  let rec perform_syntax_highlighting tab start stop =
    (* Printf.printf "perform_syntax_highlighting (start: (%d, %d); stop: (%d, %d))\n" start#line start#line_index stop#line stop#line_index; flush stdout; *)
    let buffer = tab#buffer in
    let firstLine = buffer#start_iter#get_text ~stop:buffer#start_iter#forward_to_line_end in
    let {annot_char=annotChar} = try get_file_options firstLine with FileOptionsError _ -> default_file_options in
    let commentTag = get $. GtkText.TagTable.lookup buffer#tag_table "comment" in
    let commentTag = new GText.tag commentTag in
    let ghostRangeTag = get $. GtkText.TagTable.lookup buffer#tag_table "ghostRange" in
    let ghostRangeTag = new GText.tag ghostRangeTag in
    let start = start#backward_line in
    let start = if start#line_index <> 0 then buffer#start_iter else start in (* Works around an apparent bug in backward_line *)
    let stop = stop#forward_line in
    let startLine = start#line in
    (* Printf.printf "  expanded: (start: (%d, %d); stop: (%d, %d))\n" start#line start#line_index stop#line stop#line_index; flush stdout; *)
    let startIsInComment = start#has_tag commentTag && not (start#begins_tag (Some commentTag)) || start#ends_tag (Some commentTag) in
    let startIsInGhostRange = start#has_tag ghostRangeTag && not (start#begins_tag (Some ghostRangeTag)) || start#ends_tag (Some ghostRangeTag) in
    let stopIsInComment = stop#has_tag commentTag && not (stop#ends_tag (Some commentTag)) || stop#begins_tag (Some commentTag) in
    let stopIsInGhostRange = stop#has_tag ghostRangeTag && not (stop#ends_tag (Some ghostRangeTag)) || stop#begins_tag (Some ghostRangeTag) in
    (* Printf.printf "startIsInComment: %B; startIsInGhostRange: %B; stopIsInComment: %B; stopIsInGhostRange: %B\n" startIsInComment startIsInGhostRange stopIsInComment stopIsInGhostRange; flush stdout; *)
    buffer#remove_all_tags ~start:start ~stop:stop;
    let reportRange kind ((_, line1, col1), (_, line2, col2)) =
      apply_tag_by_name tab (tag_name_of_range_kind kind) ~start:(srcpos_iter buffer (startLine + line1, col1)) ~stop:(srcpos_iter buffer (startLine + line2, col2))
    in
    let text = start#get_text ~stop:stop in
    let highlight keywords ghost_keywords =
      let (loc, ignore_eol, tokenStream, in_comment, in_ghost_range) =
        make_lexer_helper keywords ghost_keywords "<buffer>" text reportRange startIsInComment startIsInGhostRange false (fun _ _ -> ()) annotChar in
      Stream.iter (fun _ -> ()) tokenStream;
      (* Printf.printf "!in_comment: %B; !in_ghost_range: %B\n" !in_comment !in_ghost_range; flush stdout; *)
      if not (stop#is_end) && (!in_comment, !in_ghost_range) <> (stopIsInComment, stopIsInGhostRange) then
        perform_syntax_highlighting tab stop buffer#end_iter
    in
    match !(tab#path) with
      None -> ()
    | Some (path, mtime) ->
      if Filename.check_suffix path ".c" || Filename.check_suffix path ".h" then highlight c_keywords ghost_keywords
      else if Filename.check_suffix path ".java" || Filename.check_suffix path ".javaspec" then highlight java_keywords ghost_keywords
      else if Filename.check_suffix path ".cpp" || Filename.check_suffix path ".hpp" then highlight cxx_keywords ghost_keywords
      else if Filename.check_suffix path ".rs" then highlight rust_keywords rust_ghost_keywords
      else ()
  in
  let create_editor (textNotebook: GPack.notebook) buffer lineMarksTable stmtExecCountsColumn =
    let textLabel = GMisc.label ~text:"(untitled)" () in
    let textVbox = GPack.vbox ~spacing:2 ~packing:(fun widget -> ignore (textNotebook#append_page ~tab_label:textLabel#coerce widget)) () in
    let textFindBox = GPack.hbox ~show:false ~border_width:2 ~spacing:2 ~packing:(textVbox#pack ~expand:false) () in
    ignore (GMisc.label ~text:"Find:" ~packing:(textFindBox#pack ~expand:false) ());
    let textFindEntry = GEdit.entry ~packing:textFindBox#add () in
    let textScroll =
      GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN
        ~packing:textVbox#add () in
    let srcText = (*GText.view*) SourceView.source_view ~insert_spaces_instead_of_tabs:true ~source_buffer:buffer ~packing:textScroll#add () in
    lineMarksTable#show_in_source_view srcText;
    stmtExecCountsColumn#show_in_source_view srcText;
    srcText#misc#modify_font_by_name !scaledCodeFont;
    ignore $. textFindEntry#event#connect#key_press ~callback:(fun key ->
      if GdkEvent.Key.keyval key = GdkKeysyms._Escape then begin
        (new GObj.misc_ops srcText#as_widget)#grab_focus (); textFindBox#misc#hide (); true
      end else false
    );
    ignore $. textFindEntry#connect#activate ~callback:(fun () ->
      let found (iter1, iter2) =
        buffer#select_range iter1 iter2;
        srcText#scroll_to_mark ~within_margin:0.2 `INSERT
      in
      let needle = textFindEntry#text in
      let cursor = buffer#get_iter `INSERT in
      match cursor#forward_char#forward_search needle with
        None -> 
        begin match (buffer#get_iter `START)#forward_search needle with
          None -> GToolbox.message_box ~title:"VeriFast IDE" "Text not found"
        | Some range -> found range
        end
      | Some range -> found range
    );
    ignore $. srcText#event#connect#key_press ~callback:(fun key ->
      if GdkEvent.Key.keyval key = GdkKeysyms._f && List.mem `CONTROL (GdkEvent.Key.state key) then begin
        textFindBox#misc#show (); (new GObj.misc_ops textFindEntry#as_widget)#grab_focus (); true
      end else if GdkEvent.Key.keyval key = GdkKeysyms._d && List.mem `CONTROL (GdkEvent.Key.state key) then begin
        let cursor = buffer#get_iter `INSERT in
        cursor#tags |> List.iter (fun (tag: GText.tag) -> ignore (tag#event srcText#as_widget (key: GdkEvent.Key.t :> GdkEvent.any) cursor#as_iter));
        true
      end else if GdkEvent.Key.keyval key = GdkKeysyms._Return then
      begin
        let cursor = buffer#get_iter `INSERT in
        let lineStart = cursor#set_line_offset 0 in
        let rec iter home =
          if home#ends_line then home else if Glib.Unichar.isspace home#char then iter home#forward_char else home
        in
        let home = iter lineStart in
        let indent = lineStart#get_text ~stop:home in
        let eol = "\n" in
        buffer#insert (eol ^ indent);
        srcText#scroll_mark_onscreen `INSERT;
        true
      end
      else
        false
    );
    object method label = textLabel method page = textVbox method view = srcText end
  in
  let add_buffer() =
    let path = ref None in
    let buffer = SourceView.source_buffer () in
    let lineMarksTable = GLineMarks.table () in
    let stmtExecCountsColumn = GLineMarks.source_gutter_text_column "99x" 1.0 in
    buffer#begin_not_undoable_action (); (* Disable the source view's undo manager since we handle undos ourselves. *)
    let apply_tag_enabled = ref false in (* To prevent tag copying when pasting from clipboard *)
    ignore $. buffer#connect#apply_tag ~callback:(fun tag ~start ~stop -> if not !apply_tag_enabled then GtkSignal.emit_stop_by_name buffer#as_buffer ~name:"apply-tag");
    let _ = buffer#create_tag ~name:"keyword" [`WEIGHT `BOLD; `FOREGROUND "Blue"] in
    let _ = buffer#create_tag ~name:"ghostRange" [`FOREGROUND "#CC6600"] in
    let _ = buffer#create_tag ~name:"ghostKeyword" [`WEIGHT `BOLD; `FOREGROUND "#DB9900"] in
    let _ = buffer#create_tag ~name:"comment" [`FOREGROUND "#008000"] in
    let _ = buffer#create_tag ~name:"ghostRangeDelimiter" [`FOREGROUND "Gray"] in
    let _ = buffer#create_tag ~name:"error" [`UNDERLINE `DOUBLE; `FOREGROUND "Red"] in
    let _ = buffer#create_tag ~name:"currentLine" [`BACKGROUND "Yellow"] in
    let _ = buffer#create_tag ~name:"currentCaller" [`BACKGROUND "#44FF44"] in
    let currentStepMark = buffer#create_mark (buffer#start_iter) in
    let currentCallerMark = buffer#create_mark (buffer#start_iter) in
    let mainView = create_editor textNotebook buffer lineMarksTable stmtExecCountsColumn in
    let subView = create_editor subNotebook buffer lineMarksTable stmtExecCountsColumn in
    let undoList: undo_action list ref = ref [] in
    let redoList: undo_action list ref = ref [] in
    let eol = ref (if platform = Windows then "\r\n" else "\n") in
    let useSiteTags = ref [] in
    let tab = object
      method apply_tag_enabled = apply_tag_enabled
      method path = path
      method eol = eol
      method buffer = buffer
      method undoList = undoList
      method redoList = redoList
      method mainView = mainView
      method subView = subView
      method currentStepMark = currentStepMark
      method currentCallerMark = currentCallerMark
      method useSiteTags = useSiteTags
      method lineMarksTable = lineMarksTable
      method stmtExecCountsColumn = stmtExecCountsColumn
    end in
    ignore $. buffer#connect#modified_changed ~callback:(fun () ->
      updateBufferTitle tab;
      (* should be "no color" (i.e. theme's default), but the API does
         not seem to provide it. *)
      messageEntry#coerce#misc#modify_base [`NORMAL, `NAME "gray"];
      messageEntry#coerce#misc#modify_text [`NORMAL, `NAME "black"]
    );
    ignore $. buffer#connect#insert_text ~callback:(fun iter text ->
      if not !ignore_text_changes then
      begin
        let offset = iter#offset in
        undoList :=
          begin
            match !undoList with
              Insert (offset0, text0)::acs when offset = offset0 + String.length text0 ->
              Insert (offset0, text0 ^ text)::acs
            | acs -> Insert (offset, text)::acs
          end;
        redoList := [];
        undoAction#set_sensitive true;
        redoAction#set_sensitive false
      end
    );
    ignore $. buffer#connect#after#insert_text ~callback:(fun iter text ->
      let start = iter#backward_chars (Glib.Utf8.length text) in
      perform_syntax_highlighting tab start iter
    );
    ignore $. buffer#connect#after#delete_range ~callback:(fun ~start:start ~stop:stop ->
      perform_syntax_highlighting tab start stop
    );
    ignore $. buffer#connect#delete_range ~callback:(fun ~start:start ~stop:stop ->
      if not !ignore_text_changes then
      begin
        let offset = start#offset in
        let text = buffer#get_text ~start:start ~stop:stop () in
        undoList := 
          begin
            match !undoList with
              Delete (offset0, text0)::acs when offset = offset0 ->
              Delete (offset0, text0 ^ text)::acs
            | acs -> Delete (offset, text)::acs
          end;
        redoList := [];
        undoAction#set_sensitive true;
        redoAction#set_sensitive false
      end
    );
    ignore $. buffer#connect#changed ~callback:(fun () -> !bufferChangeListener tab);
    let focusIn _ = set_current_tab (Some tab); false in
    ignore $. mainView#view#event#connect#focus_in ~callback:focusIn;
    ignore $. subView#view#event#connect#focus_in ~callback:focusIn;
    buffers := !buffers @ [tab];
    tab
  in
  let setTabWidth tabSize =
    List.iter
      begin fun tab ->
        tab#mainView#view#set_tab_width tabSize;
        tab#subView#view#set_tab_width tabSize;
      end
      !buffers
  in
  let setCodeFont fontName =
    codeFont := fontName;
    let scaledFont = getScaledFont fontName in
    scaledCodeFont := scaledFont;
    List.iter
      begin fun tab ->
        tab#mainView#view#misc#modify_font_by_name scaledFont;
        tab#subView#view#misc#modify_font_by_name scaledFont
      end
      !buffers
  in
  let updateMessageEntry (success: bool) =
    (match !msg with
      None -> messageEntry#coerce#misc#hide(); fixButton#coerce#misc#hide(); helpButton#coerce#misc#hide()
    | Some msg ->
      let (backColor, textColor) = if success then ("green", "black") else ("red", "white") in
      messageEntry#coerce#misc#show();
      messageEntry#set_text msg;
      if not !messageEntryCheckDone then begin
        messageEntryCheckDone := true;
        if messageEntry#misc#get_flag `NO_WINDOW then Printf.printf "warning: GtkEntry has flag GTK_NO_WINDOW; error message may not be visible in toolbar\n";
      end;
      messageEntry#coerce#misc#modify_base [`NORMAL, `NAME backColor];
      messageEntry#coerce#misc#modify_text [`NORMAL, `NAME textColor]);
    (match (parse_error_attributes !url).help_topic with
      None -> helpButton#coerce#misc#hide()
    | Some(_) -> helpButton#coerce#misc#show();
    );
    begin match (parse_error_attributes !url).quick_fixes with
      [] -> fixButton#coerce#misc#hide()
    | _ -> fixButton#coerce#misc#show()
    end
  in
  let load tab newPath =
    try
      let chan = open_in_bin newPath in
      let text = input_fully chan in
      let mtime = in_channel_last_modification_time chan in
      close_in chan;
      let text = file_to_utf8 text in
      let (eol, text) = normalize_to_lf text in
      ignore_text_changes := true;
      let buffer = tab#buffer in
      buffer#delete ~start:buffer#start_iter ~stop:buffer#end_iter;
      let gIter = buffer#start_iter in
      tab#eol := eol;
      (buffer: SourceView.source_buffer)#insert ~iter:gIter text;
      let {tab_size=tabSize} = try get_file_options text with FileOptionsError _ -> default_file_options in
      tab#mainView#view#set_tab_width tabSize;
      tab#subView#view#set_tab_width tabSize;
      ignore_text_changes := false;
      tab#undoList := [];
      tab#redoList := [];
      buffer#set_modified false;
      tab#path := Some (newPath, mtime);
      perform_syntax_highlighting tab buffer#start_iter buffer#end_iter;
      updateBufferTitle tab;
      Some newPath
    with Sys_error msg -> GToolbox.message_box ~title:"VeriFast IDE" ("Could not load file: " ^ msg); None
  in
  let open_path path =
    let tab = add_buffer () in
    ignore $. load tab path;
    updateWhenTabListChanges ();
    tab
  in
  let new_buffer () =
    let tab = add_buffer () in
    updateWhenTabListChanges ();
    tab
  in
  begin
    let tab =
      match initialPath with
        None -> updateOpenRecentMenu (); new_buffer ()
      | Some path -> register_recent_file path; open_path path
    in
    set_current_tab (Some tab)
  end;
  let store tab thePath =
    let chan = open_out_bin thePath in
    let text = (tab#buffer: SourceView.source_buffer)#get_text () in
    output_string chan (utf8_to_file (convert_eol !(tab#eol) text));
    flush chan;
    (* let mtime = out_channel_last_modification_time chan in *)
    close_out chan;
    let mtime = path_last_modification_time thePath in
    tab#path := Some (thePath, mtime);
    tab#buffer#set_modified false;
    updateBufferTitle tab;
    updateWhenTabListChanges ();
    Some thePath
  in
  let select_file_last_dir = ref "" in
  let rec saveAs tab =
    match GToolbox.select_file ~title:"Save" ~dir:select_file_last_dir () with
      None -> None
    | Some thePath ->
      if Sys.file_exists thePath then
        match GToolbox.question_box ~title:"VeriFast" ~buttons:["Yes"; "No"; "Cancel"] "The file already exists. Overwrite?" with
          1 -> register_recent_file thePath; store tab thePath
        | 2 -> saveAs tab
        | _ -> None
      else begin
        register_recent_file thePath;
        store tab thePath
      end
  in
  let save_core tab thePath mtime =
    if file_has_changed thePath mtime then begin
      match GToolbox.question_box ~title:thePath ~buttons:["Save As"; "Overwrite"; "Cancel"] "This file has been modified by another program." with
        1 -> saveAs tab
      | 2 -> store tab thePath
      | 3 -> None
      | _ -> failwith "cannot happen"
    end else
      store tab thePath
  in
  let save tab =
    match !(tab#path) with
      None -> saveAs tab
    | Some (thePath, mtime) ->
      save_core tab thePath mtime
  in
  let bottomTable = GPack.paned (match layout with FourThree -> `HORIZONTAL | Widescreen -> `VERTICAL) () in
  let bottomTable2 = GPack.paned (match layout with FourThree -> `HORIZONTAL | Widescreen -> `VERTICAL) () in
  let _ = bottomTable#pack2 ~resize:true ~shrink:true (bottomTable2#coerce) in
  let () = (match layout with FourThree -> rootTable#pack2 | Widescreen -> rootTable#pack1) ~resize:true ~shrink:true (bottomTable#coerce) in
  let create_steplistbox =
    let collist = new GTree.column_list in
    let col_data = collist#add Gobject.Data.caml in
    let col_text = collist#add Gobject.Data.string in
    let store = GTree.tree_store collist in
    let scrollWin = GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN () in
    let lb = GTree.view ~model:store ~packing:scrollWin#add () in
    lb#coerce#misc#modify_font_by_name !scaledTraceFont;
    let col = GTree.view_column ~title:"Steps" ~renderer:(GTree.cell_renderer_text [], ["text", col_text]) () in
    let _ = lb#append_column col in
    (scrollWin, lb, col_data, col_text, col, store)
  in
  let create_listbox title =
    let collist = new GTree.column_list in
    let col_k = collist#add Gobject.Data.int in
    let col_text = collist#add Gobject.Data.string in
    let col_foreground = collist#add Gobject.Data.string in
    let col_strikethrough = collist#add Gobject.Data.boolean in
    let store = GTree.list_store collist in
    let scrollWin = GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN () in
    let lb = GTree.view ~model:store ~packing:scrollWin#add () in
    lb#coerce#misc#modify_font_by_name !scaledTraceFont;
    let col = GTree.view_column ~title:title ~renderer:(GTree.cell_renderer_text [], ["text", col_text; "foreground", col_foreground; "strikethrough", (Obj.magic (col_strikethrough: bool GTree.column): string GTree.column)]) () in (* Using Obj.magic to work around the fact that the type of GTree.view_column is more strict than necessary: it incorrectly requires that all columns be of the same type. *)
    let _ = lb#append_column col in
    (scrollWin, lb, col_k, col_text, col_foreground, col_strikethrough, col, store)
  in
  let create_assoc_list_box title1 title2 =
    let collist = new GTree.column_list in
    let col_k = collist#add Gobject.Data.int in
    let col_text1 = collist#add Gobject.Data.string in
    let col_text2 = collist#add Gobject.Data.string in
    let store = GTree.list_store collist in
    let scrollWin = GBin.scrolled_window ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ~shadow_type:`IN () in
    let lb = GTree.view ~model:store ~packing:scrollWin#add () in
    lb#coerce#misc#modify_font_by_name !scaledTraceFont;
    let col1 = GTree.view_column ~title:title1 ~renderer:(GTree.cell_renderer_text [`FONT !codeFont], ["text", col_text1]) () in
    col1#set_resizable true;
    ignore (lb#append_column col1);
    let col2 = GTree.view_column ~title:title2 ~renderer:(GTree.cell_renderer_text [], ["text", col_text2]) () in
    ignore (lb#append_column col2);
    (scrollWin, lb, col_k, col_text1, col_text2, col1, col2, store)
  in
  let (steplistFrame, stepList, stepDataCol, stepCol, stepViewCol, stepStore) = create_steplistbox in
  let _ = bottomTable#pack1 ~resize:true ~shrink:true (steplistFrame#coerce) in
  let (assumptionsFrame, assumptionsList, assumptionsKCol, assumptionsCol, assumptionsForegroundCol, assumptionsStrikethroughCol, _, assumptionsStore) = create_listbox "Assumptions" in
  let _ = bottomTable2#pack1 ~resize:true ~shrink:true (assumptionsFrame#coerce) in
  let (chunksFrame, chunksList, chunksKCol, chunksCol, chunksForegroundCol, chunksStrikethroughCol, _, chunksStore) = create_listbox "Heap chunks" in
  let _ = bottomTable2#pack2 ~resize:true ~shrink:true (chunksFrame#coerce) in
  let (srcEnvFrame, srcEnvList, srcEnvKCol, srcEnvCol1, srcEnvCol2, _, _, srcEnvStore) = create_assoc_list_box "Local" "Value" in
  let _ = srcPaned#pack2 ~resize:true ~shrink:true (srcEnvFrame#coerce) in
  let (subEnvFrame, subEnvList, subEnvKCol, subEnvCol1, subEnvCol2, _, _, subEnvStore) = create_assoc_list_box "Local" "Value" in
  let _ = subPaned#pack2 ~resize:true ~shrink:true (subEnvFrame#coerce) in
  let setTraceFont fontName =
    traceFont := fontName;
    let scaledFont = getScaledFont fontName in
    scaledTraceFont := scaledFont;
    let setFont widget = widget#coerce#misc#modify_font_by_name scaledFont in
    setFont stepList;
    setFont assumptionsList;
    setFont chunksList;
    setFont srcEnvList;
    setFont subEnvList;
    setFont messageEntry
  in
  let setFontScalePower power =
    fontScalePower := power;
    setCodeFont !codeFont;
    setTraceFont !traceFont
  in
  ignore $. (actionGroup#get_action "TextLarger")#connect#activate ~callback:(fun () -> setFontScalePower (!fontScalePower + 1));
  ignore $. (actionGroup#get_action "TextSmaller")#connect#activate ~callback:(fun () -> setFontScalePower (!fontScalePower - 1));
  ignore $. (actionGroup#get_action "TextSizeDefault")#connect#activate ~callback:(fun () -> setFontScalePower 0);
  let showExecutionTree () =
    if treeSeparator#max_position - treeSeparator#position < 10 then
      treeSeparator#set_position (treeSeparator#max_position * 85 / 100)
    else
      treeSeparator#set_position treeSeparator#max_position
  in
  ignore $. (actionGroup#get_action "ShowExecutionTree")#connect#activate ~callback:showExecutionTree;
  let get_tab_for_path path0 =
    (* This function is called only at a time when no buffers are modified. *)
    let rec iter k tabs =
      match tabs with
        tab::tabs ->
        begin match !(tab#path) with Some (path1, mtime) when path1 = path0 -> (k, tab) | _ -> iter (k + 1) tabs end
      | [] ->
        let tab = open_path path0 in (k, tab)
    in
    iter 0 !buffers
  in
  let create_marks_of_loc (p1, p2) =
    let (path1, line1, col1) = p1 in
    let (path2, line2, col2) = p2 in
    assert (path1 = path2);
    let (_, tab) = get_tab_for_path path1 in
    let buffer = tab#buffer in
    let mark1 = buffer#create_mark (srcpos_iter buffer (line1, col1)) in
    let mark2 = buffer#create_mark (srcpos_iter buffer (line2, col2)) in
    (tab, mark1, mark2)
  in
  let stepItems = ref None in
  let clearStepItems() =
    match !stepItems with
      None -> ()
    | Some (path, items) ->
      List.iter
        begin fun (ass, h, env, (tab, mark1, mark2), msg, locstack) ->
          tab#lineMarksTable#clear;
          let buffer = tab#buffer in
          buffer#delete_mark (`MARK mark1);
          buffer#delete_mark (`MARK mark2)
        end
        items;
      stepItems := None
  in
  let updateStepItems() =
    clearStepItems();
    let Some (path, ctxts_lifo) = !ctxts_lifo in
    let ctxts_fifo = List.rev ctxts_lifo in
    let rec iter lastItem itstack last_it ass locstack last_loc last_env ctxts =
      match ctxts with
        [] -> []
      | Assuming t::cs -> iter lastItem itstack last_it (t::ass) locstack last_loc last_env cs
      | Executing (h, env, l, msg)::cs ->
        let it = stepStore#append ?parent:(match itstack with [] -> None | it::_ -> Some it) () in
        let l = create_marks_of_loc (root_caller_token l) in
        let stepItem = (ass, h, env, l, msg, locstack) in
        stepStore#set ~row:it ~column:stepDataCol stepItem;
        stepStore#set ~row:it ~column:stepCol msg;
        stepItem::iter (Some stepItem) itstack (Some it) ass locstack (Some l) (Some env) cs
      | PushSubcontext::cs ->
        (match (last_it, last_loc, last_env) with 
          | (Some it, Some l, Some env) -> iter lastItem (it::itstack) None ass ((l, env)::locstack) None None cs
          | _ -> assert false
        )
      | PopSubcontext::cs ->
        (match (itstack, locstack) with 
          |(it::itstack, (l, env)::locstack) -> iter lastItem itstack (Some it) ass locstack (Some l) (Some env) cs
          | _ -> assert false
        )
      | Branching branch::cs ->
        let it = stepStore#append ?parent:(match itstack with [] -> None | it::_ -> Some it) () in
        let Some lastItem_ = lastItem in (* We assume this is not the first item in the trace. *)
        let (_, _, _, l, _, lastItemLocstack) = lastItem_ in
        let (rootCaller, _) = let rec last xs = match xs with [x] -> x | _::xs -> last xs in last ((l, [])::lastItemLocstack) in
        let (tab, startMark, endMark) = rootCaller in
        tab#lineMarksTable#add startMark (match branch with LeftBranch -> leftBranchPixbuf | RightBranch -> rightBranchPixbuf);
        stepStore#set ~row:it ~column:stepDataCol lastItem_;
        stepStore#set ~row:it ~column:stepCol (match branch with LeftBranch -> "Executing first branch" | RightBranch -> "Executing second branch");
        iter lastItem itstack (Some it) ass locstack last_loc last_env cs
    in
    stepItems := Some (path, iter None [] None [] [] None None ctxts_fifo)
  in
  let append_items (store:GTree.list_store) kcol col foreground_col strikethrough_col items =
    let rec iter k items =
      match items with
        [] -> ()
      | (item, foreground, strikethrough)::items ->
        let gIter = store#append() in
        store#set ~row:gIter ~column:kcol k;
        store#set ~row:gIter ~column:col item;
        store#set ~row:gIter ~column:foreground_col foreground;
        store#set ~row:gIter ~column:strikethrough_col strikethrough;
        iter (k + 1) items
    in
    iter 0 items
  in
  let append_assoc_items (store:GTree.list_store) kcol col1 col2 items =
    let rec iter k items =
      match items with
        [] -> ()
      | (item1, item2)::items ->
        let gIter = store#append() in
        store#set ~row:gIter ~column:kcol k;
        store#set ~row:gIter ~column:col1 item1;
        store#set ~row:gIter ~column:col2 item2;
        iter (k + 1) items
    in
    iter 0 items
  in
  let clearStepInfo() =
    List.iter (fun tab ->
      let buffer = tab#buffer in
      buffer#remove_tag_by_name "currentLine" ~start:buffer#start_iter ~stop:buffer#end_iter;
      buffer#remove_tag_by_name "currentCaller" ~start:buffer#start_iter ~stop:buffer#end_iter
    ) !buffers;
    assumptionsStore#clear();
    chunksStore#clear();
    srcEnvStore#clear();
    subEnvStore#clear()
  in
  let apply_tag_at_marks name (tab, mark1, mark2) =
    let buffer = tab#buffer in
    apply_tag_by_name tab name ~start:(buffer#get_iter_at_mark (`MARK mark1)) ~stop:(buffer#get_iter_at_mark (`MARK mark2))
  in
  let apply_tag_by_loc name (p1, p2) =
    let (path1, line1, col1) = p1 in
    let (path2, line2, col2) = p2 in
    assert (path1 = path2);
    let (_, tab) = get_tab_for_path path1 in
    let buffer = tab#buffer in
    apply_tag_by_name tab name ~start:(srcpos_iter buffer (line1, col1)) ~stop:(srcpos_iter buffer (line2, col2))
  in
  let get_step_of_path selpath =
    let gIter = stepStore#get_iter selpath in
    stepStore#get ~row:gIter ~column:stepDataCol
  in
  let strings_of_env env =
    let env = remove_dups env in
    let compare_bindings (x1, v1) (x2, v2) = compare x1 x2 in
    let env = List.sort compare_bindings env in
    List.filter (fun entry -> entry <> ("currentThread", "currentThread")) env
  in
  let rec get_last_visible_descendant (treeView: GTree.view) path =
    if treeView#row_expanded path then
      let iter = treeView#model#get_iter path in
      let n = treeView#model#iter_n_children (Some iter) in
      let iter = treeView#model#iter_children ~nth:(n - 1) (Some iter) in
      get_last_visible_descendant treeView (treeView#model#get_path iter)
    else
      path
  in
  let get_path_of_preceding_visible_row treeView path =
    let path = GtkTree.TreePath.copy path in
    if GtkTree.TreePath.prev path then
      Some (get_last_visible_descendant treeView path)
    else if GtkTree.TreePath.up path && GtkTree.TreePath.get_depth path > 0 then
      Some path
    else
      None
  in
  let stepSelected _ =
    match !stepItems with
      None -> ()
    | Some (path, stepItems) ->
      let language, dialect = file_specs path in
      let open StringOf(struct let string_of_type = string_of_type language dialect end) in
      clearStepInfo();
      let selpath = List.hd stepList#selection#get_selected_rows in
      let (ass, h, env, l, msg, locstack) = get_step_of_path selpath in
      let prevRowPath = get_path_of_preceding_visible_row stepList selpath in
      let prevStep = option_map get_step_of_path prevRowPath in
      begin
        match locstack with
          [] ->
          if textPaned#max_position - textPaned#position < 10 then
            textPaned#set_position 0;
          apply_tag_at_marks "currentLine" l;
          let (tab, mark1, _) = l in
          goto_tab tab textNotebook;
          tab#buffer#move_mark (`MARK tab#currentStepMark) ~where:(tab#buffer#get_iter_at_mark (`MARK mark1));
          ignore $. Glib.Idle.add(fun () -> tab#mainView#view#scroll_to_mark ~within_margin:0.2 (`MARK tab#currentStepMark); false);
          append_assoc_items srcEnvStore srcEnvKCol srcEnvCol1 srcEnvCol2 (strings_of_env env)
        | (caller_loc, caller_env)::_ ->
          if textPaned#max_position >= 300 && textPaned#position < 10 || textPaned#max_position - textPaned#position < 10 then
            textPaned#set_position 150;
          begin
            apply_tag_at_marks "currentLine" l;
            let (tab, mark1, _) = l in
            let k = index_of_byref tab !buffers in
            subNotebook#goto_page k;
            tab#buffer#move_mark (`MARK tab#currentStepMark) ~where:(tab#buffer#get_iter_at_mark (`MARK mark1));
            ignore $. Glib.Idle.add (fun () -> tab#subView#view#scroll_to_mark ~within_margin:0.2 (`MARK tab#currentStepMark); false); 
            append_assoc_items subEnvStore subEnvKCol subEnvCol1 subEnvCol2 (strings_of_env env)
          end;
          begin
            apply_tag_at_marks "currentCaller" caller_loc;
            let (tab, mark1, _) = caller_loc in
            goto_tab tab textNotebook;
            tab#buffer#move_mark (`MARK tab#currentCallerMark) ~where:(tab#buffer#get_iter_at_mark (`MARK mark1));
            ignore $. Glib.Idle.add(fun () -> tab#mainView#view#scroll_to_mark ~within_margin:0.2 (`MARK tab#currentCallerMark); false);
            append_assoc_items srcEnvStore srcEnvKCol srcEnvCol1 srcEnvCol2 (strings_of_env caller_env)
          end
      end;
      let unchangedRowColor = "#000000" in
      let newRowColor = "#00C000" in
      let deletedRowColor = "#FF0000" in
      let assRows =
        match prevStep with
          None -> List.map (fun s -> (s, unchangedRowColor, false)) ass
        | Some (ass', _, _, _, _, _) ->
          let delta = List.length ass - List.length ass' in
          let rec iter delta ass =
            if delta = 0 then
              List.map (fun s -> (s, unchangedRowColor, false)) ass
            else
              let s::ass = ass in
              (s, newRowColor, false)::iter (delta - 1) ass
          in
          iter delta ass
      in
      append_items assumptionsStore assumptionsKCol assumptionsCol assumptionsForegroundCol assumptionsStrikethroughCol (List.rev assRows);
      let compare_chunks (Chunk ((g, literal), targs, coef, ts, size)) (Chunk ((g', literal'), targs', coef', ts', size')) =
        let r = compare g g' in
        if r <> 0 then r else
        let rec compare_list xs ys =
          match (xs, ys) with
            ([], []) -> 0
          | (x::xs, y::ys) ->
            let r = compare x y in
            if r <> 0 then r else compare_list xs ys
          | _ -> assert false
        in
        let r = compare (string_of_targs targs) (string_of_targs targs') in
        if r <> 0 then r else
        let r = compare_list ts ts' in
        if r <> 0 then r else
        compare coef coef'
      in
      let chunksRows =
        let h = List.map string_of_chunk (List.sort compare_chunks h) in
        match prevStep with
          None -> List.map (fun c -> (c, unchangedRowColor, false)) h
        | Some (_, h', _, _, _, _) ->
          let h' = List.map string_of_chunk (List.sort compare_chunks h') in
          let rec iter h h' =
            match h, h' with
              [], [] -> []
            | c::h, c'::h' when c = c' ->
              (c, unchangedRowColor, false)::iter h h'
            | h, c'::h' when not (List.mem c' h) ->
              (c', deletedRowColor, true)::iter h h'
            | c::h, h' ->
              (c, newRowColor, false)::iter h h'
          in
          iter h h'
      in
      append_items chunksStore chunksKCol chunksCol chunksForegroundCol chunksStrikethroughCol chunksRows
  in
  let _ = stepList#connect#cursor_changed ~callback:stepSelected in
  let _ = (new GObj.misc_ops stepList#as_widget)#grab_focus() in
  let get_last_step_path() =
    let lastBigStep = stepStore#iter_children ~nth:(stepStore#iter_n_children None - 1) None in
    let lastBigStepChildCount = stepStore#iter_n_children (Some lastBigStep) in
    let lastStep = if lastBigStepChildCount > 0 then stepStore#iter_children ~nth:(lastBigStepChildCount - 1) (Some lastBigStep) else lastBigStep in
    stepStore#get_path lastStep
  in
  let updateStepListView() =
    stepList#expand_all();
    let lastStepRowPath = get_last_step_path() in
    let _ = stepList#selection#select_path lastStepRowPath in
    Glib.Idle.add (fun () -> stepList#scroll_to_cell lastStepRowPath stepViewCol; false)
  in
  let ensureSaved tab =
    if tab#buffer#modified then
      match GToolbox.question_box ~title:"VeriFast" ~buttons:["Save"; "Discard"; "Cancel"] "There are unsaved changes." with
        1 -> (match save tab with None -> true | Some _ -> false)
      | 2 -> false
      | _ -> true
    else
      false
  in
  let _ = root#connect#destroy ~callback:GMain.Main.quit in
  let clearTrace() =
    if !msg <> None then
    begin
      msg := None;
      url := None;
      clearStepItems();
      updateMessageEntry(false);
      clearStepInfo();
      stepStore#clear();
      List.iter (fun tab ->
        let buffer = tab#buffer in
        buffer#remove_tag_by_name "error" ~start:buffer#start_iter ~stop:buffer#end_iter;
        tab#stmtExecCountsColumn#clear
      ) !buffers
    end
  in
  bufferChangeListener := (fun tab ->
    ()
  );
  ignore $. root#event#connect#delete ~callback:(fun _ ->
    let rec iter tabs =
      match tabs with
        [] -> false
      | tab::tabs -> ensureSaved tab || iter tabs
    in
    iter !buffers
  );
  let get_current_tab() =
    match !current_tab with
      Some tab -> Some tab
    | None -> GToolbox.message_box ~title:"VeriFast IDE" ("Please select a buffer."); None
  in
  let close tab =
    (* Returns true if canceled *)
    ensureSaved tab ||
    begin
      clearTrace();
      textNotebook#remove tab#mainView#page#coerce;
      subNotebook#remove tab#subView#page#coerce;
      buffers := List.filter (fun tab0 -> not (tab0 == tab)) !buffers;
      begin match !current_tab with None -> () | Some tab0 -> if tab == tab0 then set_current_tab None end;
      updateWhenTabListChanges ();
      false
    end
  in
  let rec close_all () =
    (* Returns true if canceled *)
    match !buffers with
      [] -> false
    | tab::_ ->
      close tab || close_all ()
  in
  ignore $. (actionGroup#get_action "New")#connect#activate ~callback:(fun _ ->
    ignore (close_all () || (ignore $. new_buffer (); false))
  );
  let user_open_path thePath =
    if not (close_all ()) then begin
      select_file_last_dir := Filename.dirname thePath;
      register_recent_file thePath;
      ignore (open_path thePath)
    end
  in
  open_recent_folder_func := begin fun folder ->
    match GToolbox.select_file ~title:"Open" ~dir:(ref "") ~filename:(Filename.concat folder "") () with
      None -> ()
    | Some thePath -> user_open_path thePath
  end;
  open_recent_file_func := begin fun path ->
    if not (Sys.file_exists path) then
      GToolbox.message_box ~title:"VeriFast IDE" ("File has been moved or deleted: " ^ path)
    else
      user_open_path path
  end;
  ignore $. (actionGroup#get_action "Open")#connect#activate ~callback:(fun _ ->
    match GToolbox.select_file ~title:"Open" ~dir:select_file_last_dir () with
      None -> ()
    | Some thePath -> user_open_path thePath
  );
  ignore $. (actionGroup#get_action "Save")#connect#activate ~callback:(fun () -> match get_current_tab() with Some tab -> ignore $. save tab | None -> ());
  ignore $. (actionGroup#get_action "SaveAs")#connect#activate ~callback:(fun () -> match get_current_tab() with Some tab -> ignore $. saveAs tab | None -> ());
  ignore $. (actionGroup#get_action "Close")#connect#activate ~callback:(fun () -> match get_current_tab() with Some tab -> ignore $. close tab | None -> ());
  let go_to_loc l =
    let (start, stop) = l in
    let (path, line, col) = start in
    let (k, tab) = get_tab_for_path path in
    textNotebook#goto_page k;
    let buffer = tab#buffer in
    let it = srcpos_iter buffer (line, col) in
    buffer#place_cursor ~where:it;
    ignore $. Glib.Idle.add (fun () -> ignore $. tab#mainView#view#scroll_to_iter ~within_margin:0.2 it; (* NOTE: scroll_to_iter returns a boolean *) false);
    ()
  in
  let fix_button_clicked () =
    match (parse_error_attributes !url).quick_fixes with
      [] -> ()
    | (descr, InsertTextAt (insertPos, textToInsert))::_ ->
      let (path, line, col) = insertPos in
      let (k, tab) = get_tab_for_path path in
      textNotebook#goto_page k;
      let buffer = tab#buffer in
      let it = srcpos_iter buffer (line, col) in
      buffer#place_cursor ~where:it;
      buffer#insert ~iter:it textToInsert;
      ignore $. Glib.Idle.add (fun () -> ignore $. tab#mainView#view#scroll_to_iter ~within_margin:0.2 it; (* NOTE: scroll_to_iter returns a boolean *) false);
  in
  ignore (fixButton#connect#clicked ~callback:fix_button_clicked);
  let handleStaticError l emsg eurl =
    if l <> dummy_loc then
      apply_tag_by_loc "error" (root_caller_token l);
    msg := Some emsg;
    url := eurl;
    updateMessageEntry(false);
    if l <> dummy_loc then
      go_to_loc (root_caller_token l)
  in
  let reportRange kind l =
    apply_tag_by_loc (tag_name_of_range_kind kind) l
  in
  let reportUseSite declKind declLoc useSiteLoc =
    let (useSiteStart, useSiteStop) = useSiteLoc in
    let (useSitePath, useSiteLine, useSiteCol) = useSiteStart in
    let (_, useSiteStopLine, useSiteStopCol) = useSiteStop in
    let (useSiteK, useSiteTab) = get_tab_for_path useSitePath in
    let useSiteBuffer = useSiteTab#buffer in
    let useSiteTag = useSiteBuffer#create_tag [] in
    useSiteTab#useSiteTags := useSiteTag::!(useSiteTab#useSiteTags);
    ignore $. useSiteTag#connect#event ~callback:begin fun ~origin event iter ->
      if GdkEvent.get_type event = `KEY_PRESS then begin
        let key = GdkEvent.Key.cast event in
        if GdkEvent.Key.keyval key = GdkKeysyms._d && List.mem `CONTROL (GdkEvent.Key.state key) then begin
          if textPaned#max_position >= 300 && textPaned#position < 10 || textPaned#max_position - textPaned#position < 10 then
            textPaned#set_position 150;
          begin
            let (tab, mark1, _) = create_marks_of_loc declLoc in
            let k = index_of_byref tab !buffers in
            subNotebook#goto_page k;
            ignore $. Glib.Idle.add (fun () -> tab#subView#view#scroll_to_mark ~within_margin:0.2 (`MARK mark1); false)
          end
        end
      end;
      false
    end;
    apply_tag useSiteTab useSiteTag ~start:(srcpos_iter useSiteBuffer (useSiteLine, useSiteCol)) ~stop:(srcpos_iter useSiteBuffer (useSiteStopLine, useSiteStopCol))
  in
  let ensureHasPath tab =
    match !(tab#path) with
      None -> save tab
    | Some (path, mtime) ->
      if tab#buffer#modified then
        save_core tab path mtime
      else if file_has_changed path mtime then begin
       print_endline (Printf.sprintf "File '%s' has been changed by another program; reloading from disk..." path);
       load tab path
      end else
        Some path
  in
  let undo () =
    match get_current_tab() with
      None -> ()
    | Some tab ->
      let buffer = tab#buffer in
      begin
        match !(tab#undoList) with
          [] -> ()
        | ac::acs ->
          ignore_text_changes := true;
          let offset =
            match ac with
              Insert (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              let stop = buffer#get_iter (`OFFSET (offset + String.length text)) in
              buffer#delete ~start:start ~stop:stop;
              offset
            | Delete (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              buffer#insert ~iter:start text;
              offset + String.length text
          in
          ignore_text_changes := false;
          tab#undoList := acs;
          tab#redoList := ac::!(tab#redoList);
          undoAction#set_sensitive (acs <> []);
          redoAction#set_sensitive true;
          buffer#place_cursor ~where:(buffer#get_iter (`OFFSET offset));
          tab#mainView#view#scroll_to_mark ~within_margin:0.2 `INSERT 
      end
  in
  let redo () =
    match get_current_tab() with
      None -> ()
    | Some tab ->
      let buffer = tab#buffer in
      begin
        match !(tab#redoList) with
          [] -> ()
        | ac::acs ->
          ignore_text_changes := true;
          let offset =
            match ac with
              Insert (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              buffer#insert ~iter:start text;
              offset + String.length text
            | Delete (offset, text) ->
              let start = buffer#get_iter (`OFFSET offset) in
              let stop = buffer#get_iter (`OFFSET (offset + String.length text)) in
              buffer#delete ~start:start ~stop:stop;
              offset
          in
          ignore_text_changes := false;
          tab#redoList := acs;
          tab#undoList := ac::!(tab#undoList);
          undoAction#set_sensitive true;
          redoAction#set_sensitive (acs <> []);
          buffer#place_cursor ~where:(buffer#get_iter (`OFFSET offset));
          tab#mainView#view#scroll_to_mark ~within_margin:0.2 `INSERT
      end
  in
  let sync_with_disk tab =
    (* Ensure the buffer contents are equal to the file contents. Returns true on cancellation. *)
    match !(tab#path) with
      None -> false
    | Some (path, mtime) ->
      if tab#buffer#modified then
        match save_core tab path mtime with Some _ -> false | None -> true
      else
        file_has_changed path mtime && close tab
  in
  let clearSyntaxHighlighting () =
    !buffers |> List.iter begin fun tab ->
      let buffer = tab#buffer in
      buffer#remove_all_tags ~start:buffer#start_iter ~stop:buffer#end_iter;
      let tagTable = new GText.tag_table buffer#tag_table in
      !(tab#useSiteTags) |> List.iter (fun tag -> tagTable#remove tag#as_tag);
      tab#useSiteTags := []
    end
  in
  let getCursor () =
    begin match !current_tab with
      None -> None
    | Some tab ->
      match !(tab#path) with
        None -> None
      | Some (path, mtime) ->
        let buffer = tab#buffer in
        let insert_iter = buffer#get_iter_at_mark `INSERT in
        let insert_line = insert_iter#line in
        Some (path, insert_line + 1)
    end
  in
  let verifyProgram runToCursor focus targetPath () =
    msg := Some("Verifying...");
    updateMessageEntry(false);
    clearTrace();
    match !buffers with
      [] -> ()
    | tab::tabs ->
      begin
        match ensureHasPath tab with
          None -> ()
        | Some path ->
          clearSyntaxHighlighting();
          if not (List.exists sync_with_disk tabs) then
          begin
            let breakpoint =
              if runToCursor then
                getCursor ()
              else
                None
            in
            let focus =
              if focus then
                getCursor ()
              else
                None
            in
            let postProcess = ref (fun () -> ()) in
            begin try
              let options = {
                option_verbose = 0;
                option_verbose_flags = [];
                option_use_java_frontend = !useJavaFrontend;
                option_enforce_annotations = enforceAnnotations;
                option_allow_should_fail = true;
                option_allow_ignore_ref_creation = true;
                option_emit_manifest = false;
                option_check_manifest = false;
                option_vroots = [crt_vroot default_bindir];
                option_allow_assume = true;
                option_provides = [];
                option_keep_provide_files = true;
                option_vfbindings = !vfbindings;
                option_safe_mode = false;
                option_header_whitelist = [];
                option_report_skipped_stmts = false;
              }
              in
              let reportExecutionForest =
                if targetPath <> None then
                  (fun _ -> ())
                else
                  (fun forest -> postProcess := (fun () -> reportExecutionForest !forest))
              in
              if options.option_use_java_frontend || Filename.check_suffix path ".cpp" || Filename.check_suffix path ".hpp" || Filename.check_suffix path ".rs" then begin
                !buffers |> List.iter begin fun tab ->
                  perform_syntax_highlighting tab tab#buffer#start_iter tab#buffer#end_iter
                end
              end;
              let hasStmts = InfiniteArray.make false in
              let lineCount = ref 0 in
              let reportStmt ((path', line, _), _) =
                if path' == path then begin
                  InfiniteArray.set hasStmts (line - 1) true;
                  lineCount := max !lineCount line
                end
              in
              let stmtExecCounts = InfiniteArray.make 0 in
              let reportStmtExec ((path', line, _), _) =
                if path' == path then
                  InfiniteArray.set stmtExecCounts (line - 1) (InfiniteArray.get stmtExecCounts (line - 1) + 1)
              in
              let reportDirective directive loc =
                match directive with
                  "allow_dead_code" -> true
                | _ -> false
              in
              let prover, options = merge_options_from_source_file prover options path in
              let stats = verify_program prover options path {reportRange; reportUseSite; reportStmt; reportStmtExec; reportExecutionForest; reportDirective} breakpoint focus targetPath in
              begin
                let _, tab = get_tab_for_path path in
                let column = tab#stmtExecCountsColumn in
                for i = 0 to !lineCount - 1 do
                  column#add_line (if InfiniteArray.get hasStmts i then Printf.sprintf "%dx" (InfiniteArray.get stmtExecCounts i) else "")
                done
              end;
              let success =
                if targetPath <> None then
                  (msg := Some("0 errors found (target path not reached)"); false)
                else if runToCursor then
                  (msg := Some("0 errors found (cursor is unreachable)"); false)
                else
                  (msg := Some(stats#get_success_message); true)
              in
              updateMessageEntry(success)
            with
              PreprocessorDivergence (l, emsg) ->
              handleStaticError (Lexed l) ("Preprocessing error" ^ (if emsg = "" then "." else ": " ^ emsg)) None
            | ParseException (l, emsg) ->
              let message = "Parse error" ^ (if emsg = "" then "." else ": " ^ emsg) in
              if (l = Ast.dummy_loc) then begin
                msg := Some(message);
                updateMessageEntry(false)
              end
              else
                handleStaticError l message None
            | CompilationError(emsg) ->
              clearTrace();
              msg := Some(emsg);
              updateMessageEntry(false)
            | CompilationErrorWithDetails (emsg, details) ->
              clearTrace();
              print_endline details;
              msg := Some (emsg ^ " (see console for details)");
              updateMessageEntry false
            | StaticError (l, emsg, eurl) ->
              handleStaticError l emsg eurl
            | RustcErrors (l, emsg, diagnostics) ->
              let open Json in
              List.iter (fun d -> Printf.printf "%s" (o_assoc "rendered" d |> s_value)) diagnostics;
              print_newline ();
              handleStaticError l (emsg ^ " (see console for details)") None
            | SymbolicExecutionError (ctxts, l, emsg, eurl) ->
              ctxts_lifo := Some (path, ctxts);
              updateStepItems();
              ignore $. updateStepListView();
              stepSelected();
              (* let (ass, h, env, steploc, stepmsg, locstack) = get_step_of_path (get_last_step_path()) in *)
              begin match ctxts with
                Executing (_, _, steploc, _)::_ when l = steploc ->
                apply_tag_by_loc "error" (root_caller_token l);
                msg := Some emsg;
                url := eurl;
                updateMessageEntry(false)
              | _ ->
                handleStaticError l emsg eurl
              end
            | e ->
              prerr_endline ("VeriFast internal error: \n" ^ Printexc.to_string e ^ "\n");
              Printexc.print_backtrace Stdlib.stderr;
              flush Stdlib.stderr;
              GToolbox.message_box ~title:"VeriFast IDE" "Verification failed due to an internal error. See the console window for details."
            end;
            !postProcess ()
          end
      end
  in
  let runShapeAnalyser () =
    (* TODO: after running the shape analyser, the undo history
     * has the step "clear buffer" and "put contents", but that should
     * be only one undo step. This requires adding a new undo type, 'Replace'.
     * This would theoretically also solve the program that pasting over a
     * selection ends up incorrectly as two undo steps.*)
    match (get_current_tab(), getCursor()) with
      (None, _) -> () (* get_current_tab already shows messagebox on error *)
      | (_, None) ->
        GToolbox.message_box ~title:"VeriFast IDE" ("First place the cursor" ^
          " inside the function you want to perform shape analysis on.")
      | (Some tab, cursor) ->
        match !(tab#path) with
          None -> GToolbox.message_box ~title:"VeriFast IDE" ("Error: current tab" ^
            " has no path.")
        | Some (path, mtime) ->
          if file_type path <> CLang then
            (* It should be possible to support anything since we work on
             * the AST, so this is just because there is no (known) code yet to
             * call the correct parser. *)
            GToolbox.message_box ~title:"VeriFast IDE" ("The shape analyser currently" ^
            " only supports C programs")
          else begin
            (* Save all tabs to disk firsts. Only continue on success. *)
            if not (List.exists sync_with_disk !buffers) then begin
              try begin
                let new_contents = shape_analyse_frontend path (Vfbindings.get Vfparam_include_paths !vfbindings) (Vfbindings.get Vfparam_define_macros !vfbindings) (getCursor ()) in
                let buffer = tab#buffer in
                buffer#set_text new_contents;
                (* syntax highlighting gets updated automatically *)
                clearTrace();
                ()
              end with
              | ParseException (l, emsg) ->
                handleStaticError l ("Parse error" ^
                  (if emsg = "" then "." else ": " ^ emsg)) None;
                ()
              | ShapeAnalysisException (l, message) ->
                handleStaticError l ("Shape analysis error: " ^ message) None;
                ()
            end
          end
  in
  begin
    let open TreeMetrics in
    ignore $. treeDrawingArea#event#connect#expose ~callback:begin fun event ->
      let d = new GDraw.drawable treeDrawingArea#misc#window in
      let delayedCommands = ref [] in
      let performDelayed f = delayedCommands := f::!delayedCommands in
      let rec drawNode x y (TreeNode (nodeType, w, h, ns)) =
        let px = x + cw * w / 2 in
        let py = y + cw / 2 in
        let (outlineColor, fillColor) =
          match nodeType with
            ExecNode _ -> None, `BLACK
          | BranchNode -> if ns = [] then Some `BLACK, `NAME "lightgray" else None, `NAME "darkgray"
          | SuccessNode -> None, `NAME "green"
          | ErrorNode -> None, `NAME "red"
        in
        performDelayed begin fun () ->
          d#set_foreground fillColor;
          let x = px - dotWidth / 2 in
          let y = py - dotWidth / 2 in
          d#arc ~x ~y ~width:dotWidth ~height:dotWidth ~filled:true ();
          begin match outlineColor with
            None -> ()
          | Some outlineColor ->
            d#set_foreground outlineColor;
            d#arc ~x ~y ~width:dotWidth ~height:dotWidth ~filled:false ()
          end
        end;
        let rec drawChildren x y ns =
          match ns with
            [] -> ()
          | n::ns ->
            let (w, cx, cy) = drawNode x y n in
            d#line ~x:px ~y:py ~x:cx ~y:cy;
            drawChildren (x + w * cw) y ns
        in
        drawChildren x (y + cw) ns;
        (w, px, py)
      in
      let drawTree tree =
        ignore $. drawNode 0 0 tree;
        !delayedCommands |> List.iter (fun f -> f ())
      in
      let active = treeCombo#active in
      if 0 <= active then drawTree (List.nth !executionForest active);
      true
    end;
    treeDrawingArea#event#add [`BUTTON_PRESS; `BUTTON_RELEASE];
    ignore $. treeDrawingArea#event#connect#button_release ~callback:begin fun event ->
      let bx, by = int_of_float (GdkEvent.Button.x event), int_of_float (GdkEvent.Button.y event) in
      let rec hitTest x y (TreeNode (nodeType, w, h, ns)) =
        if by < y + cw then begin
          let px = x + cw * w / 2 in
          let py = y + cw / 2 in
          if abs (by - py) <= dotRadius && abs (bx - px) <= dotRadius then
            begin match nodeType with
              ExecNode (msg, p) -> verifyProgram false false (Some p) ()
            | _ -> ()
            end
        end else begin
          let rec testChildren x y ns =
            match ns with
              [] -> ()
            | (TreeNode (_, w, _, _) as n)::ns ->
              if bx < x + cw * w then
                hitTest x y n
              else
                testChildren (x + cw * w) y ns
          in
          testChildren x (y + cw) ns
        end
      in
      let active = treeCombo#active in
      if 0 <= active then hitTest 0 0 (List.nth !executionForest active);
      true
    end
  end;
  let showPreferencesDialog () =
    let dialog = GWindow.dialog ~title:"Preferences" ~parent:root () in
    let vbox = dialog#vbox in
    let itemsTable = GPack.table ~rows:3 ~columns:2 ~border_width:4 ~row_spacings:4 ~col_spacings:4 ~packing:(vbox#pack ~from:`START ~expand:true) () in
    ignore $. GMisc.label ~text:"Code font:" ~packing:(itemsTable#attach ~left:0 ~top:0 ~expand:`X) ();
    let codeFontButton = GButton.font_button ~font_name:!codeFont ~show:true ~packing:(itemsTable#attach ~left:1 ~top:0 ~expand:`X) () in
    ignore $. GMisc.label ~text:"Trace font:" ~packing:(itemsTable#attach ~left:0 ~top:1 ~expand:`X) ();
    let traceFontButton = GButton.font_button ~font_name:!traceFont ~show:true ~packing:(itemsTable#attach ~left:1 ~top:1 ~expand:`X) () in
    ignore $. GMisc.label ~text:"Tab width:" ~packing:(itemsTable#attach ~left:0 ~top:2 ~expand:`X) ();
    let currentTabWidth = string_of_int (List.hd !buffers)#mainView#view#tab_width in
    let newTabSize = GEdit.entry ~text:currentTabWidth ~max_length:500 ~packing:(itemsTable#attach ~left:1 ~top:2 ~expand:`X) () in
    let okButton = GButton.button ~stock:`OK ~packing:dialog#action_area#add () in
    ignore $. okButton#connect#clicked ~callback:(fun () ->
      match int_of_string_opt newTabSize#text with
        None -> ()
      | Some n -> setTabWidth n;
      setCodeFont codeFontButton#font_name;
      setTraceFont traceFontButton#font_name;
      dialog#response `DELETE_EVENT
    );
    let cancelButton = GButton.button ~stock:`CANCEL ~packing:dialog#action_area#add () in
    ignore $. cancelButton#connect#clicked ~callback:(fun () -> dialog#response `DELETE_EVENT);
    ignore $. dialog#run();
    dialog#destroy()
  in
  let add_include_path_gui gui_input () =
    let text = gui_input#text in
    if (String.length text > 0) then
      vfbindings := Vfbindings.set Vfparam_include_paths [text] !vfbindings
  in
  let showIncludesDialog () =
    let dialog = GWindow.dialog ~title:"Include Paths" ~parent:root () in
    let vbox = dialog#vbox in
    let itemsTable = GPack.table ~rows:2 ~columns:2 ~border_width:4 ~row_spacings:4 ~col_spacings:4 ~packing:(vbox#pack ~from:`START ~expand:true) () in
    ignore $. GMisc.label ~text:"Current paths:" ~packing:(itemsTable#attach ~left:0 ~top:0 ~expand:`X) ();
    ignore $. GMisc.label ~text:(String.concat ":" (Vfbindings.get Vfparam_include_paths !vfbindings)) ~packing:(itemsTable#attach ~left:1 ~top:0 ~expand:`X) ();
    ignore $. GMisc.label ~text:"Add path:" ~packing:(itemsTable#attach ~left:0 ~top:1 ~expand:`X) ();
    let new_include = GEdit.entry ~text:"" ~max_length:500 ~packing:(itemsTable#attach ~left:1 ~top:1 ~expand:`X) () in
    ignore $. new_include#connect#activate ~callback:(add_include_path_gui new_include);
    let okButton = GButton.button ~stock:`OK ~packing:dialog#action_area#add () in
    ignore $. okButton#connect#clicked ~callback:(fun () ->
      add_include_path_gui new_include ();
      dialog#response `DELETE_EVENT
    );
    let cancelButton = GButton.button ~stock:`CANCEL ~packing:dialog#action_area#add () in
    ignore $. cancelButton#connect#clicked ~callback:(fun () -> dialog#response `DELETE_EVENT);
    ignore $. dialog#run();
    dialog#destroy()
  in
  
  (* Dialog that allows the user to select a tab of the notebook by simply typing (part of) the name.
   *  This is sometimes faster than searching visually. *)
  let showFindFileDialog notebook () =
    let dialog = GWindow.dialog ~title:"Find file" ~parent:root () in
    dialog#add_button_stock `OK `OK;
    dialog#add_button_stock `CANCEL `CANCEL;
    dialog#set_default_response `OK;
    let vbox = dialog#vbox in
    let entry = GEdit.entry ~text:"" ~max_length:500 ~packing:(vbox#pack ~from:`START ~expand: true) ~activates_default:true () in
    let label = GMisc.label ~text:"(no search results yet)" ~packing:(vbox#pack ~expand:true) () in
    
    
    let google (haystack: string list) (needle: string) : string option = 
      
      let rec get_first_filter_match (filters : ('a -> bool) list) (haystack : 'a list) : 'a option =
        match filters with
        | [] -> None
        | filter::tail ->
          try
            Some(List.find filter haystack)
          with
          Not_found -> get_first_filter_match tail haystack
      in
      
      (* This is probably a bit inefficient. *)
      let contains (haystack: string) (needle: string) : bool =
        let rec iter i =
          if i < 0 then
            false
          else begin
            if String.sub haystack i (String.length needle) = needle then
              true
            else
              iter (i - 1)
          end
        in
        iter ((String.length haystack) - (String.length needle))
      in
      
      let filters = [
        
        (* Find a file that starts with what the user types *)
        (startswith needle);
        
        (* Find matches of the form "x/yz" for a search "y" *)
        (fun bigstring -> contains bigstring ("/" ^ needle));
        
        (* Find matches that just contain what the user types*)
        (fun bigstring -> contains bigstring needle)
      ] in
      
      if needle = "" then
        None
      else
        get_first_filter_match filters haystack
    in
    
    (* Gets the list of names of tabs and tabs. *)
    let search_tabs () =
      let items = !buffers |> List.map (fun tab -> (getTitleOfTab tab), tab) in
      let items = List.sort (fun (name1, _) (name2, _) -> compare name1 name2) items in
      let (item_strings, _) = List.split items in
      (item_strings, items)
    in
    
    (* Jump to the tab that matches the best with the entry's text *)
    let jump_to_tab () =
      (* If you do this somewhere else, you will sooner or later
       * end up using outdated data. *)
      let (item_strings, items) = search_tabs() in
      
      begin match google item_strings entry#text with
        | None -> ()
        | Some(match_) ->
          let tab = List.assoc match_ items in
          goto_tab tab notebook
      end
    in
    
    (* Performs search and updates the search results in the GUI *)
    let show_finds () =
      let (item_strings, items) = search_tabs() in
      let text = match google item_strings entry#text with
          None -> "(no results)"
          | Some(match_) -> match_
      in
      label#set_text text
    in
    
    ignore $. entry#connect#changed ~callback:show_finds;
    match dialog#run () with
      `OK ->
        jump_to_tab ();
        dialog#destroy()
      | `DELETE_EVENT | `CANCEL -> dialog#destroy()
  in
  
  ignore $. (actionGroup#get_action "ClearTrace")#connect#activate ~callback:clearTrace;
  ignore $. (actionGroup#get_action "Preferences")#connect#activate ~callback:showPreferencesDialog;
  ignore $. (actionGroup#get_action "VerifyProgram")#connect#activate ~callback:(verifyProgram false false None);
  ignore $. (actionGroup#get_action "VerifyFunction")#connect#activate ~callback:(verifyProgram false true None);
  ignore $. (actionGroup#get_action "RunToCursor")#connect#activate ~callback:(verifyProgram true false None);
  ignore $. (actionGroup#get_action "RunShapeAnalysis")#connect#activate ~callback:runShapeAnalyser;
  ignore $. (actionGroup#get_action "Include paths")#connect#activate ~callback:showIncludesDialog;
  ignore $. (actionGroup#get_action "Find file (top window)")#connect#activate ~callback:(showFindFileDialog subNotebook);
  ignore $. (actionGroup#get_action "Find file (bottom window)")#connect#activate ~callback:(showFindFileDialog textNotebook);
  ignore $. undoAction#connect#activate ~callback:undo;
  ignore $. redoAction#connect#activate ~callback:redo;
  ignore $. root#event#connect#focus_in ~callback:begin fun _ ->
    !buffers |> List.iter begin fun tab ->
      match !(tab#path) with
        None -> ()
      | Some (path, mtime) ->
        if not tab#buffer#modified && Sys.file_exists path && file_has_changed path mtime then begin
          print_endline (Printf.sprintf "File '%s' has been changed by another program; reloading from disk..." path);
          ignore (load tab path)
        end
    end;
    false
  end;
  root#show();
  ignore $. Glib.Idle.add (fun () -> textPaned#set_position 0; false);
  if verifyAndQuit then begin
    ignore $. Glib.Idle.add begin fun () ->
      verifyProgram false false None ();
      ignore $. Glib.Idle.add (fun () -> exit 0);
      false
    end
  end;
  GMain.main()

let (code_font, trace_font) =
  match platform with
    MacOS -> ("Menlo 12", "Sans 12")
  | _ -> ("Monospace 10", "Sans 8")

let () =
  let path = ref None in
  let prover = ref default_prover in
  let codeFont = ref code_font in
  let traceFont = ref trace_font in
  let layout = ref FourThree in
  let javaFrontend = ref false in
  let enforceAnnotations = ref false in
  let vfbindings = ref Vfbindings.default in
  let verify_and_quit = ref false in
  let rec iter args =
    match args with
      "-prover"::arg::args -> prover := arg; iter args
    | "-codeFont"::arg::args -> codeFont := arg; iter args
    | "-traceFont"::arg::args -> traceFont := arg; iter args
    | "-bindir"::arg::args -> Util.set_bindir arg; iter args
    | "-layout"::"fourthree"::args -> layout := FourThree; iter args
    | "-layout"::"widescreen"::args -> layout := Widescreen; iter args
    | "-javac"::args -> javaFrontend := true; iter args
    | "-enforce_annotations"::args -> enforceAnnotations := true; iter args
    | "-verify_and_quit"::args -> verify_and_quit := true; iter args
    | arg::args when startswith arg "-" && List.mem_assoc (String.sub arg 1 (String.length arg - 1)) vfparams ->
      let (Vfparam vfparam, _) = List.assoc (String.sub arg 1 (String.length arg - 1)) vfparams in
      begin match vfparam_info_of vfparam with
        BoolParam -> vfbindings := Vfbindings.set vfparam true !vfbindings; iter args
      | ParsedParam (_, parseFunc, _) ->
        begin match args with
          [] -> failwith ("Bad command line: option '" ^ arg ^ "' takes an argument")
        | arg::args ->
          vfbindings := Vfbindings.set vfparam (parseFunc arg) !vfbindings;
          iter args
        end
      end
    | "-rustc_args"::arg::args ->
      vfbindings := Vfbindings.set Vfparam_rustc_args (List.rev (String.split_on_char ' ' arg)) !vfbindings;
      iter args
    | arg::args when not (startswith arg "-") -> path := Some arg; iter args
    | [] -> show_ide !path !prover !codeFont !traceFont !vfbindings !layout !javaFrontend !enforceAnnotations !verify_and_quit
    | _ ->
      let options = [
        "-prover prover    (" ^ list_provers () ^ ")";
        "-codeFont fontSpec";
        "-traceFont fontSpec";
        "-layout fourthree|widescreen";
        "-javac";
        "-bindir";
        "-enforce_annotations"
      ] @ List.map (fun (paramName, (_, description)) -> "-" ^ paramName ^ "   " ^ description) vfparams in
      GToolbox.message_box ~title:"VeriFast IDE" begin
        "Invalid command line.\n\n" ^ 
        "Usage: vfide [options] [filepath]\n\n" ^
        "Options:\n" ^
        String.concat "" (List.map (fun opt -> "  " ^ opt ^ "\n") options)
      end
  in
  let args = 
    match Array.to_list (Sys.argv) with
    | _::args -> args
    | _ -> assert false
  in
  iter args
