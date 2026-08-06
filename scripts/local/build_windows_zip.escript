%%! -noshell

%% Erlang escript: zip a Windows ERTS dir with all subdirs preserved.
%%
%% This is the portable replacement for the lost `zip-shim` that used to
%% wrap `zip -qr`. The upstream `otp_win64_<v>.zip` from erlang/otp comes
%% with a full release-style tree (`bin/`, `erts-X.Y.Z/bin/`, `lib/`,
%% `releases/<v>/`, etc.); the previous shim only kept the top-level files
%% and dropped every subdir, which broke the batamanta Fetcher/Packager
%% downstream.
%%
%% Usage: escript build_windows_zip.escript <SrcDir> <OutZip>
%%
%% SrcDir must contain the unpacked upstream contents directly (no wrapper
%% subdir) — i.e. `bin/`, `erts-X.Y.Z/`, `lib/`, `releases/` all at the root.
%% On exit:
%%   exit 0: zip written successfully
%%   exit 1: any error (with a message on stderr)

main([SrcDir, OutZip]) ->
    %% Strip bloat we don't need at runtime:
    %%   - `doc/` and `usr/` (Qt/GTK docs, ~30-40MB)
    %%   - INSTALL.txt, installer.sha256, vc_redist.exe
    %%   - per-erts `doc/` subdirs (HTML docs)
    BloatTop = ["doc", "usr", "INSTALL.txt", "installer.sha256", "vc_redist.exe"],
    lists:foreach(fun(Name) ->
        Path = filename:join(SrcDir, Name),
        case file:read_file_info(Path) of
            {ok, _} -> delete_recursive(Path);
            _ -> ok
        end
    end, BloatTop),

    %% Remove `erts-*/doc/` HTML docs.
    case file:list_dir(SrcDir) of
        {ok, Names} ->
            lists:foreach(fun(N) ->
                case string:prefix(N, "erts-") of
                    nomatch -> ok;
                    _ ->
                        DocPath = filename:join([SrcDir, N, "doc"]),
                        case file:read_file_info(DocPath) of
                            {ok, _} -> delete_recursive(DocPath);
                            _ -> ok
                        end
                end
            end, Names);
        _ -> ok
    end,

    %% Strip legacy install metadata (defensive — usually absent).
    lists:foreach(fun(Name) ->
        Path = filename:join(SrcDir, Name),
        file:delete(Path)
    end, ["InstallInfo", "Install.ini", "Uninstall.exe", "setup.exe"]),

    %% Make sure the parent dir of OutZip exists, then zip.
    ZipName = filename:absname(OutZip),
    OutDir = filename:dirname(ZipName),
    file:make_dir(OutDir),
    {ok, OriginalCwd} = file:get_cwd(),

    ok = file:set_cwd(SrcDir),
    try
        Files = collect_files("."),
        Result = zip:create(ZipName, Files, []),
        case Result of
            {ok, _} ->
                {ok, Info} = file:read_file_info(ZipName),
                io:format("OK ~p bytes~n", [element(6, Info)]),
                halt(0);
            {error, Reason} ->
                io:format(standard_error, "ERROR: ~p~n", [Reason]),
                halt(1)
        end
    after
        file:set_cwd(OriginalCwd)
    end.

%% Walk the tree starting at Dir, returning the relative forward-slash
%% path of every regular file (zip uses forward slashes regardless of OS).
collect_files(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:flatmap(fun(N) ->
                Full = filename:join(Dir, N),
                case file:read_file_info(Full) of
                    {ok, FI} ->
                        case element(3, FI) of
                            directory -> collect_files(Full);
                            regular -> [to_arcname(Full)];
                            _ -> []
                        end;
                    _ -> []
                end
            end, Names);
        _ -> []
    end.

to_arcname(Full) ->
    lists:flatten(lists:map(fun($\\) -> $/; (C) -> C end, Full)).

delete_recursive(Path) ->
    case file:read_file_info(Path) of
        {ok, FI} ->
            case element(3, FI) of
                directory ->
                    case file:list_dir(Path) of
                        {ok, Ns} ->
                            lists:foreach(fun(N) -> delete_recursive(filename:join(Path, N)) end, Ns);
                        _ -> ok
                    end,
                    file:del_dir(Path);
                regular ->
                    file:delete(Path);
                _ -> ok
            end;
        _ -> ok
    end.
