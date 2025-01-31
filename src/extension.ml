open Js_of_ocaml
open Vscode
open Format

(*List of all the languages the controller supports*)
let supported_languages =
  [
    "ocaml";
    "markdown";
    "html";
    "javascript";
    "latex";
    "perl";
    "powershell";
    "raw";
    "ruby";
    "shellscript";
    "sql";
    "xml";
  ]

module Jupyter_notebook = struct
  type output = {
    ename : string;
    evalue : string;
    output_type : string;
    traceback : string list;
  }
  [@@deriving yojson]

  type cell_type = Code [@name "code"] | Markdown [@name "markdown"]
  [@@deriving yojson]

  type cell_metadata_vscode = { language_id : string [@key "languageId"] }
  [@@deriving yojson]

  type cell_metadata = { vscode : cell_metadata_vscode } [@@deriving yojson]

  type cell = {
    cell_type : cell_type;
    metadata : cell_metadata;
    source : string list;
    outputs : output list;
  }
  [@@deriving yojson]

  type t = { nbformat : int; nbformat_minor : int; cells : cell list }
  [@@deriving yojson]
end

let deserializeNotebook ~content ~token:_ =
  (* a function that converts a Jupyter_notebook.cell to NotebookCellData.t *)
  let jupyter_cell_to_vscode (jupyter_cell : Jupyter_notebook.cell) =
    let open Jupyter_notebook in
    let kind =
      match jupyter_cell with
      | { cell_type = Code; _ } -> NotebookCellKind.Code
      | { cell_type = Markdown; _ } -> NotebookCellKind.Markup
    in
    let languageId =
      match jupyter_cell.metadata with
      | { vscode = { language_id } } -> language_id
    in
    let value =
      match jupyter_cell with { source; _ } -> String.concat "\n" source
    in
    let notebook_cell_data = NotebookCellData.make ~kind ~languageId ~value in
    let { outputs = jupyter_outputs; _ } = jupyter_cell in
    let outputs =
      List.map
        (fun (_jupyter_output : Jupyter_notebook.output) ->
          NotebookCellOutput.make ~items:[] ())
        jupyter_outputs
    in
    NotebookCellData.set_outputs notebook_cell_data outputs;
    notebook_cell_data
  in
  (* Jupyter_notebook.t from the JSON *)
  let json_string = Buffer.to_string content in
  match String.trim json_string with
  | "" -> NotebookData.make ~cells:[]
  | json_string ->
      let json = Yojson.Safe.from_string json_string in
      let notebook = Jupyter_notebook.of_yojson json |> Result.get_ok in
      (* Build the list of NotebookCellData.t from the Jupyter_notebook.cell list that we get from cells by iterating on them and calling the function above. *)
      let cells =
        List.map jupyter_cell_to_vscode notebook.Jupyter_notebook.cells
      in
      (* Build a NotebookData.t record structure *)
      NotebookData.make ~cells

let serializeNotebook ~(data : NotebookData.t) ~token:_ =
  (* Write a function that converts a NotebookCellData.t to Jupyter_notebook.cell *)
  let vscode_to_jupyter_cell (cell_data : NotebookCellData.t) =
    let cell_type =
      match NotebookCellData.kind cell_data with
      | NotebookCellKind.Code -> Jupyter_notebook.Code
      | NotebookCellKind.Markup -> Jupyter_notebook.Markdown
    in
    let source = String.split_on_char '\n' (NotebookCellData.value cell_data) in
    let metadata =
      Jupyter_notebook.
        { vscode = { language_id = NotebookCellData.languageId cell_data } }
    in
    let output = NotebookCellData.get_outputs cell_data in
    let output_to_jupyter (_output : NotebookCellOutput.t list option) =
      Jupyter_notebook.
        {
          ename = "ename";
          evalue = "evalue";
          output_type = "code";
          traceback = [];
        }
    in
    let jupyter_output = output_to_jupyter output in
    Jupyter_notebook.
      { cell_type; source; outputs = [ jupyter_output ]; metadata }
  in

  (* Build the list of Jupyter_notebook.cell from the NotebookCellData.t list that we get from NotebookData.cells by iterating on them and calling the function above. *)
  let (cells : NotebookCellData.t list) = NotebookData.cells data in
  let (cells : Jupyter_notebook.cell list) =
    List.map vscode_to_jupyter_cell cells
  in

  (* Build a Jupyter_notebook.t record structure *)
  let jupyter_notebook_structure =
    Jupyter_notebook.{ nbformat = 0; nbformat_minor = 0; cells }
  in
  (* Convert a Jupyter_notebook.t to a JSON structure. (the PPX deriver generates a Jupyter_notebook.to_yojson function) *)
  let (json : Yojson.Safe.t) =
    Jupyter_notebook.to_yojson jupyter_notebook_structure
  in

  (* Convert the JSON structure to a string *)
  let json_string = Yojson.Safe.to_string json in

  (* Convert the JSON string to a buffer. Buffer.from_string or something. *)
  Buffer.from json_string

let notebookSerializer =
  NotebookSerializer.create ~serializeNotebook ~deserializeNotebook

let notebook_controller =
  let id = "ocamlnotebook" in
  let notebookType = "ocamlnotebook" in
  let label = "ocamlnotebook" in
  let () = Js_of_ocaml_toplevel.JsooTop.initialize () in
  let () = Toploop.initialize_toplevel_env () in
  let counter = ref 0 in
  let handler ~(cells : NotebookCell.t list) ~notebook:_ ~controller =
    (* Create the handler *)
    let () =
      (* TODO: Run these in parallel *)
      cells
      |> List.map (fun (cell : NotebookCell.t) ->
             let open Promise.Syntax in
             let execution =
               NotebookController.createNotebookCellExecution controller ~cell
             in
             counter := !counter + 1;
             let () =
               NotebookCellExecution.set_executionOrder execution !counter
             in
             let now = (new%js Js.date_now)##getTime in
             (* Cell execution starts *)
             let () = NotebookCellExecution.start execution ~startTime:now () in
             (* Create CellOutputItem with the content of the cell *)
             let notebook_cell_output_item =
               (* We don't have a buffer in the VSCode API, this is a UInt8Array, which is part of the escript API, should be binded. *)
               let document = NotebookCell.document cell in
               let content = TextDocument.getText document () in
               let lb = Lexing.from_string content in
               let _ =
                 try
                   let toplevel_phrases = !Toploop.parse_use_file lb in
                   List.iter
                     (fun phrase ->
                       let _ =
                         Toploop.execute_phrase true Format.str_formatter phrase
                       in
                       ())
                     toplevel_phrases
                 with err ->
                   let _ = Location.report_exception Format.str_formatter err in
                   ()
               in
               let chan = stdout in
               let add_to_cell_output (s : string) =
                 fprintf str_formatter "%s" s
               in
               let cb = add_to_cell_output in
               let _ = Js_of_ocaml.Sys_js.set_channel_flusher chan cb in
               let output = Format.flush_str_formatter () in
               let data = Buffer.from output in
               let mime = "text/plain" in
               NotebookCellOutputItem.make ~data ~mime
             in
             (* Create CellOutput *)
             let notebook_cell_output =
               NotebookCellOutput.make ~items:[ notebook_cell_output_item ] ()
             in
             (* Assign the cell output to the execution (replaceOutput) *)
             let* () =
               NotebookCellExecution.replaceOutput execution
                 ~out:notebook_cell_output ~cell ()
             in
             (* Call execution.end *)
             let now = (new%js Js.date_now)##getTime in
             let () =
               NotebookCellExecution.end_ execution ~success:true ~endTime:now
                 ()
             in
             Promise.return ())
      |> Promise.all_list |> ignore
    in
    Promise.return ()
  in
  Notebooks.createNotebookController ~id ~notebookType ~label ~handler ()

let () =
  Vscode.NotebookController.set_supportsExecutionOrder notebook_controller
    (Some true)

let () =
  Vscode.NotebookController.set_supportedLanguages notebook_controller
    supported_languages

let activate (context : ExtensionContext.t) =
  let () =
    let handler ~(textEditor : TextEditor.t) ~(edit : TextEditorEdit.t) ~args:_
        =
      Toploop.initialize_toplevel_env ()
    in
    let id = "vscode-ocaml-notebooks.notebookeditor.restartkernel" in
    let dispose =
      Vscode.Commands.registerTextEditorCommand ~command:id ~callback:handler
    in
    ExtensionContext.subscribe ~disposable:dispose context
  in
  let disposable =
    Workspace.registerNotebookSerializer ~notebookType:"ocamlnotebook"
      ~serializer:notebookSerializer ()
  in
  ExtensionContext.subscribe ~disposable context

(* see {{:https://code.visualstudio.com/api/references/vscode-api#Extension}
   activate() *)
let () =
  let open Js_of_ocaml.Js in
  export "activate" (wrap_callback activate)
