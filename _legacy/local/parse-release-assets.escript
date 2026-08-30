%%! -noshell

%% Erlang escript: parse the JSON output of `gh release view --json assets`
%% and print one line per asset in the form:
%%
%%     <name> <browser_download_url>
%%
%% Replaces jq (which isn't always installed, e.g. on Windows hosts without
%% a package manager). Reads the JSON from stdin. Exits 0 on success, 1
%% on parse error.
%%
%% The Erlang `:json` module is part of the standard library since OTP 27,
%% so this works on any Erlang installation >= 27 — and we target OTP 27+
%% anyway in this repo.

main(_) ->
    Input = read_stdin(),
    case json:decode(Input) of
        #{<<"assets">> := Assets} when is_list(Assets) ->
            lists:foreach(fun(Asset) -> print_asset(Asset) end, Assets);
        _ ->
            io:format(standard_error, "ERROR: input has no 'assets' array~n", []),
            halt(1)
    end,
    halt(0).

read_stdin() ->
    %% Read all of stdin into a binary. `io:get_chars/2` reads up to N chars;
    %% we loop until we hit eof.
    read_all(<<>>).

read_all(Acc) ->
    case io:get_chars('', 65536) of
        eof -> Acc;
        {error, _} -> Acc;
        Chunk when is_list(Chunk) ->
            read_all(<<Acc/binary, (list_to_binary(Chunk))/binary>>);
        Chunk when is_binary(Chunk) ->
            read_all(<<Acc/binary, Chunk/binary>>)
    end.

%% Print one asset as: "name url"
print_asset(Asset) when is_map(Asset) ->
    Name = maps:get(<<"name">>, Asset, <<"">>),
    Url = maps:get(<<"browser_download_url">>, Asset,
                  maps:get(<<"url">>, Asset, <<"">>)),
    io:format("~s ~s~n", [Name, Url]).
