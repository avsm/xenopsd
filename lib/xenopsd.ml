(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Xenops_utils

module D = Debug.Make(struct let name = "xenopsd" end)
open D

let name = "xenopsd"

let major_version = 0
let minor_version = 9

(* Server configuration. We have built-in (hopefully) sensible defaults,
   together with command-line arguments and a configuration file. They
   are applied in order: (latest takes precedence)
      defaults < arguments < config file
*)
let config_file = ref (Printf.sprintf "/etc/%s.conf" name)
let pidfile = ref (Printf.sprintf "/var/run/%s.pid" name)
let sockets_path = ref Xenops_interface.default_sockets_dir
let sockets_group = ref "xapi"
let persist = ref true
let daemon = ref false
let worker_pool_size = ref 4

let run_hotplug_scripts = ref true
let hotplug_timeout = ref 300.
let qemu_dm_ready_timeout = ref 300.

let watch_queue_length = ref 1000

let config_spec = [
	"sockets-path", Arg.Set_string sockets_path, "Directory to create listening sockets";
    "sockets-group", Arg.Set_string sockets_group, "Group to allow access to the control socket";
    "pidfile", Arg.Set_string pidfile, "Location to store the process pid";
    "persist", Arg.Bool (fun b -> persist := b), "True if we want to persist metadata across restarts";
    "daemon", Arg.Bool (fun b -> daemon := b), "True if we want to daemonize";
    "disable-logging-for", Arg.String
        (fun x ->
            try
                let modules = Re_str.split (Re_str.regexp "[ ]+") x in
                List.iter Debug.disable modules
            with e ->
				error "Processing disabled-logging-for = %s: %s" x (Printexc.to_string e)
        ), "A space-separated list of debug modules to suppress logging from";
    "worker-pool-size", Arg.Set_int worker_pool_size, "Number of threads for the worker pool";
    "database-path", Arg.Set_string Xenops_utils.root, "Location to store the metadata";
    "config", Arg.Set_string config_file, "Location of configuration file";
    "run_hotplug_scripts", Arg.Bool (fun x -> run_hotplug_scripts := x), "True if xenopsd should execute the hotplug scripts directly";
    "hotplug_timeout", Arg.Set_float hotplug_timeout, "Time before we assume hotplug scripts have failed";
    "qemu_dm_ready_timeout", Arg.Set_float qemu_dm_ready_timeout, "Time before we assume qemu has become stuck";
    "watch_queue_length", Arg.Set_int watch_queue_length, "Maximum number of unprocessed xenstore watch events before we restart";
] @ Path.config_spec

let arg_spec = List.map (fun (a, b, c) -> "-" ^ a, b, c) config_spec

let read_config_file () =
    if Sys.file_exists !config_file then begin
		(* Will raise exception if config is mis-formatted. It's up to the
           caller to inspect and handle the failure.
        *)
        Config.parse_file !config_file config_spec;
		debug "Read global variables successfully from %s" !config_file
    end;
	(* Check the required binaries are all available *)
	List.iter
		(fun (access, name, path, descr) ->
			try
				Unix.access !path [ access ]
			with _ ->
				error "Cannot access %s: please set %s in %s" !path descr !config_file;
				error "For example:";
				error "    # %s" descr;
				error "    %s=/path/to/%s" name name;
				exit 1
		) Path.essentials

let dump_config_file () : unit =
    debug "pidfile = %s" !pidfile;
    debug "persist = %b" !persist;
    debug "daemon = %b" !daemon;
    debug "worker-pool-size = %d" !worker_pool_size;
    debug "database-path = %s" !Xenops_utils.root

let path () = Filename.concat !sockets_path "xenopsd"
let forwarded_path () = path () ^ ".forwarded" (* receive an authenticated fd from xapi *)
let json_path () = path () ^ ".json"

module Server = Xenops_interface.Server(Xenops_server)

(* Normal HTTP POST and GET *)
let http_handler s (context: Xenops_server.context) =
	let ic = Unix.in_channel_of_descr s in
	let oc = Unix.out_channel_of_descr s in
	let module Request = Cohttp.Request.Make(Cohttp_posix_io.Buffered_IO) in
	let module Response = Cohttp.Response.Make(Cohttp_posix_io.Buffered_IO) in
	match Request.read ic with
		| None ->
			debug "Failed to read HTTP request"
		| Some req ->
			begin match Request.meth req, Uri.path (Request.uri req) with
				| `GET, "/" ->
					let response_txt = "<html><body>Hello there</body></html>" in
					let headers = Cohttp.Header.of_list [
						"user-agent", "xenopsd";
						"content-length", string_of_int (String.length response_txt)
					] in
					let response = Response.make ~version:`HTTP_1_1 ~status:`OK ~headers () in
					Response.write (fun t oc -> Response.write_body t oc response_txt) response oc
				| `POST, "/" ->
					begin match Request.header req "content-length" with
						| None ->
							debug "Failed to read content-length"
						| Some content_length ->
							let content_length = int_of_string content_length in
							let request_txt = String.make content_length '\000' in
							really_input ic request_txt 0 content_length;
							let rpc_call = Jsonrpc.call_of_string request_txt in
							let rpc_response = Server.process context rpc_call in
							let response_txt = Jsonrpc.string_of_response rpc_response in
							let headers = Cohttp.Header.of_list [
								"user-agent", "xenopsd";
								"content-length", string_of_int (String.length response_txt)
							] in
							let response = Response.make ~version:`HTTP_1_1 ~status:`OK ~headers () in
							Response.write (fun t oc -> Response.write_body t oc response_txt) response oc
					end
				| _, _ ->
					let headers = Cohttp.Header.of_list [
						"user-agent", "xenopsd";
					] in
					let response = Response.make ~version:`HTTP_1_1 ~status:`Not_found ~headers () in
					Response.write (fun t oc -> ()) response oc
			end


(* Apply a binary message framing protocol where the first 16 bytes are an integer length
   stored as an ASCII string *)
let binary_handler s (context: Xenops_server.context) =
	let ic = Unix.in_channel_of_descr s in
	let oc = Unix.out_channel_of_descr s in
	(* Read a 16 byte length encoded as a string *)
	let len_buf = String.make 16 '\000' in
	really_input ic len_buf 0 (String.length len_buf);
	let len = int_of_string len_buf in
	let msg_buf = String.make len '\000' in
	really_input ic msg_buf 0 (String.length msg_buf);
	let (request: Rpc.call) = Jsonrpc.call_of_string msg_buf in
	let (result: Rpc.response) = Server.process context request in
	let msg_buf = Jsonrpc.string_of_response result in
	let len_buf = Printf.sprintf "%016d" (String.length msg_buf) in
	output_string oc len_buf;
	output_string oc msg_buf;
	flush oc

let accept_forever sock f =
	let (_: Thread.t) = Thread.create
		(fun () ->
			while true do
				let this_connection, _ = Unix.accept sock in
				let (_: Thread.t) = Thread.create
					(fun () ->
						finally
							(fun () -> f this_connection)
							(fun () -> Unix.close this_connection)
					) () in
				()
			done
		) () in
	()

let start (domain_sock, forwarded_sock, json_sock)  =
	(* JSON/HTTP over domain_sock, no fd passing *)
	accept_forever domain_sock
		(fun s ->
			let context = { Xenops_server.transferred_fd = None } in
			http_handler s context
		);

	accept_forever forwarded_sock
		(fun this_connection ->
			let msg_size = 16384 in
			let buf = String.make msg_size '\000' in
			debug "Calling recv_fd()";
			let len, _, received_fd = Fd_send_recv.recv_fd this_connection buf 0 msg_size [] in
			debug "recv_fd ok (len = %d)" len;
			finally
				(fun () ->
					let req = String.sub buf 0 len |> Jsonrpc.of_string |> Xenops_migrate.Forwarded_http_request.t_of_rpc in
					debug "Received request = [%s]\n%!" (req |> Xenops_migrate.Forwarded_http_request.rpc_of_t |> Jsonrpc.to_string);
					let expected_prefix = "/service/xenops/memory/" in
					let uri = req.Xenops_migrate.Forwarded_http_request.uri in
					if String.length uri < String.length expected_prefix || (String.sub uri 0 (String.length expected_prefix) <> expected_prefix) then begin
						error "Expected URI prefix %s, got %s" expected_prefix uri;
						let module Response = Cohttp.Response.Make(Cohttp_posix_io.Unbuffered_IO) in
						let headers = Cohttp.Header.of_list [
							"User-agent", "xenopsd"
						] in
						let response = Response.make ~version:`HTTP_1_1 ~status:`Not_found ~headers () in
						Response.write (fun _ _ -> ()) response this_connection;
					end else begin
						let context = {
							Xenops_server.transferred_fd = Some received_fd
						} in
						let uri = Uri.of_string req.Xenops_migrate.Forwarded_http_request.uri in
						Xenops_server.VM.receive_memory uri req.Xenops_migrate.Forwarded_http_request.cookie this_connection context
					end
				) (fun () -> Unix.close received_fd)
		);

	(* JSON/binary over json_sock, no fd passing *)
	accept_forever json_sock
		(fun s ->
			let context = { Xenops_server.transferred_fd = None } in
			binary_handler s context
		)

let prepare_unix_domain_socket path =
	try
		Unixext.mkdir_safe (Filename.dirname path) 0o700;
		Unixext.unlink_safe path;
		let sock = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
		Unix.bind sock (Unix.ADDR_UNIX path);
		ignore(Forkhelpers.execute_command_get_output !Path.chgrp [!sockets_group; path]);
		Unix.chmod path 0o0770;
		Unix.listen sock 5;
		sock
	with e ->
		error "Failed to listen on Unix domain socket %s. Raw error was: %s" path (Printexc.to_string e);
		begin match e with
		| Unix.Unix_error(Unix.EACCES, _, _) ->
			error "Access was denied.";
			error "Possible fixes include:";
			error "1. Run this program as root (recommended)";
			error "2. Make the permissions in the filesystem more permissive (my effective uid is %d)" (Unix.geteuid ());
			error "3. Adjust the sockets-path directive in %s" !config_file;
			exit 1
		| _ -> ()
		end;
		raise e

let main backend =
	debug "xenopsd version %d.%d starting" major_version minor_version;

	Arg.parse (Arg.align arg_spec)
		(fun _ -> failwith "Invalid argument")
		(Printf.sprintf "Usage: %s [-config filename]" name);

	read_config_file ();
	dump_config_file ();

	(* Check the sockets-group exists *)
	if try ignore(Unix.getgrnam !sockets_group); false with _ -> true then begin
		error "Group %s doesn't exist." !sockets_group;
		error "Either create the group, or select a different group by modifying the config file:";
		error "# Group which can access the control socket";
		error "sockets-group=<some group name>";
		exit 1
	end;

	if !daemon then begin
		debug "About to daemonize";
		Debug.output := Debug.syslog "xenopsd" ();
		Unixext.daemonize();
	end;

	Sys.set_signal Sys.sigpipe Sys.Signal_ignore;

	(* Accept connections before we have daemonized *)
	let domain_sock = prepare_unix_domain_socket (path ()) in
	let forwarded_sock = prepare_unix_domain_socket (forwarded_path ()) in
	let json_sock = prepare_unix_domain_socket (json_path ()) in

	Unixext.mkdir_rec (Filename.dirname !pidfile) 0o755;
	(* Unixext.pidfile_write !pidfile; *) (* XXX *)

	Xenops_utils.set_fs_backend
		(Some (if !persist
			then (module Xenops_utils.FileFS: Xenops_utils.FS)
			else (module Xenops_utils.MemFS: Xenops_utils.FS)));

	Xenops_server.register_objects();
	Xenops_server.set_backend (Some backend);

	Debug.with_thread_associated "main" start (domain_sock, forwarded_sock, json_sock);
	Scheduler.start ();
	Xenops_server.WorkerPool.start !worker_pool_size;
	while true do
		try
			Thread.delay 60.
		with e ->
			debug "Thread.delay caught: %s" (Printexc.to_string e)
	done

(* Verify the signature matches *)
module S = (Xenops_server_skeleton : Xenops_server_plugin.S)
