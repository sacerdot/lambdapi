(*
let show_form_stream ?(message="") ?(output="") request response =
  %% response
  <html>
  <body>

    <h1><a href="https://github.com/Deducteam/lambdapi">LambdaPi</a>
     Search Engine</h1>

    <p>
    The <b>search</b> button answers the query. Read the <a
    href="https://lambdapi.readthedocs.io/en/latest/query_language.html">query
    language specification</a> to learn about the query language.<br>
    </p>

    <form method="POST" action="/">
      <%s! Dream.csrf_tag request %>
      <p>
      <input type="search" required="true" size="100"
        name="message" value="<%s message %>"
        onfocus="this.select();" autofocus></p>
      <p>
      <input type="submit" value="search" name="search">
      </p>
    </form>

    <%s! output %>

  </body>
  </html>
*)

let show_form ~from ?(message="") ?output request =
  <html>
  <body>
    <script>
    function incr(delta) {
      document.getElementById("from").value =
        Math.max(0,delta + Number(document.getElementById("from").value));
      document.getElementById("search").click();
    }
    </script>

    <h1><a href="https://github.com/Deducteam/lambdapi">LambdaPi</a>
     Search Engine</h1>

    <p>
    The <b>search</b> button answers the query. Read the <a
    href="https://lambdapi.readthedocs.io/en/latest/query_language.html">query
    language specification</a> to learn about the query language.<br>
    </p>

    <form method="POST" action="/" id="form">
      <%s! Dream.csrf_tag request %>
      <p>
      <input type="search" required="true" size="100"
        name="message" value="<%s message %>"
        onfocus="this.select();" autofocus></p>
      <p>
      <input type="submit" value="search" id="search" name="search">
      </p>

%   begin match output with
%   | None ->
       <input type="hidden" name="from" value="<%s string_of_int from %>">
%   | Some output ->
    <p>
    <input type="number" required="true" style="width: 5em" min="0" id="from"
      name="from" value="<%s string_of_int from %>" onfocus="this.select()">
    <input type="button"
      name="prev" value="Prev" onclick="incr(-100)">
    <input type="button"
      name="next" value="Next" onclick="incr(100)">
    </p>
    <%s! output %>
%   end;
    </form>

  </body>
  </html>

let start ss ~port () =
  (*Common.Logger.set_debug true "e" ;*)
  Dream.run ~port
  @@ Dream.logger
  @@ Dream.memory_sessions
  @@ Dream.router [

    Dream.get  "/"
      (fun request ->
        Dream.html (show_form ~from:0 request));

    Dream.post "/"
      (fun request ->
        match%lwt Dream.form request with
        | `Ok [ "from", from; "message", message; "search", _search ] ->
          Dream.log "from1 = %s" from ;
          let from = int_of_string from in (* XXX CSC exception XXX *)
          Dream.log "from2 = %d" from ;
          let output =
            Indexing.search_cmd_html ss ~from ~how_many:100 message in
          Dream.html (show_form ~from ~message ~output request)
          (*Dream.stream (show_form_stream ~message ~output request)*)
        | _ ->
          Dream.log "no match" ;
          Dream.empty `Bad_Request);

  ]
