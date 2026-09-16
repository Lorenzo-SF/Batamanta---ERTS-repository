#!/usr/bin/fish

function build_darwin
    clear
    echo (set_color --bold green)"================================================"
    echo " 🍏 Apple Native Factory: Iniciando build darwin"
    echo "================================================"(set_color normal)
    rm -rf ~/.Trash/* 2>/dev/null
    
    set repo_root (git rev-parse --show-toplevel)
    set src_temp "$repo_root/src_temp"
    set manifest "$repo_root/MANIFEST.json"
    
    mkdir -p $src_temp
    cd $repo_root
    if not test -f $manifest; echo "{}" > $manifest; end

set versiones 25.0 25.0.1 25.0.2 25.0.3 25.0.4 25.1 25.1.1 25.1.2 25.2 25.2.1 25.2.2 25.2.3 25.3 25.3.1 25.3.2 25.3.2.1 25.3.2.2 25.3.2.3 25.3.2.4 25.3.2.5 25.3.2.6 25.3.2.7 25.3.2.8 25.3.2.9 25.3.2.10 25.3.2.11 25.3.2.12 25.3.2.13 25.3.2.14 25.3.2.15 25.3.2.16 25.3.2.17 25.3.2.18 25.3.2.19 25.3.2.20 25.3.2.21 26.0 26.0.1 26.0.2 26.1 26.1.1 26.1.2 26.2 26.2.1 26.2.2 26.2.3 26.2.4 26.2.5 26.2.5.1 26.2.5.2 26.2.5.3 26.2.5.4 26.2.5.5 26.2.5.6 26.2.5.7 26.2.5.8 26.2.5.9 26.2.5.10 26.2.5.11 26.2.5.12 26.2.5.13 26.2.5.14 26.2.5.15 26.2.5.16 26.2.5.17 27.0 27.0.1 27.1 27.1.1 27.1.2 27.1.3 27.2 27.2.1 27.2.2 27.2.3 27.2.4 27.3 27.3.1 27.3.2 27.3.3 27.3.4 27.3.4.1 27.3.4.2 27.3.4.3 27.3.4.4 27.3.4.5 27.3.4.6 27.3.4.7 27.3.4.8 28.0 28.0.1 28.0.2 28.0.3 28.0.4 28.1 28.1.1 28.2 28.3 28.3.1 28.3.2 28.3.3 28.4
    set openssl_dir (brew --prefix openssl@3 2>/dev/null)
    if test -z "$openssl_dir"; set openssl_dir (brew --prefix openssl@1.1 2>/dev/null); end

    for v in $versiones
        set v_tag "OTP-$v"
        git pull --rebase origin main >/dev/null 2>&1

        set filename "darwin-arm64.tar.gz"
        set out_file "$src_temp/$filename"
        
        set has_asset 0
        if gh release view $v_tag >/dev/null 2>&1
            if gh release view $v_tag --json assets -q '.assets[].name' | grep -q "^$filename\$"
                set has_asset 1
            end
        end

        if test $has_asset -eq 1
            echo "  ⏭️  $filename ya existe en el Release $v_tag. Saltando."
            continue
        end

        echo (set_color magenta)"\n🚀 Construyendo $filename para $v_tag"(set_color normal)
        set tarball "$src_temp/otp_src_$v.tar.gz"
        
        if not test -s $tarball
            echo -n "  📥 Descargando fuente... "
            curl -fLsL --retry 5 "https://github.com/erlang/otp/releases/download/OTP-$v/otp_src_$v.tar.gz" -o $tarball
            echo "OK"
        end

        echo -n "  🔨 Compilando... "
        set build_dir "$src_temp/build_$v"
        mkdir -p $build_dir
        tar -xzf $tarball -C $build_dir --strip-components=1
        
        if bash -c "
            cd $build_dir
            export ERL_TOP=\$(pwd)
            ./otp_build autoconf > /dev/null 2>&1
            ./configure --prefix=$src_temp/opt_erlang --without-javac --without-odbc --without-wx --without-debugger --without-observer --with-ssl=$openssl_dir > /dev/null 2>&1
            make -j\$(sysctl -n hw.ncpu) > /dev/null 2>&1
            make install > /dev/null 2>&1
            cd $src_temp/opt_erlang/lib/erlang
            sed -i '' 's|^ROOTDIR=.*|ROOTDIR=\"\$(dirname \"\$(dirname \"\$(PWD)\")\")\"|' bin/erl
            sed -i '' 's|^ROOTDIR=.*|ROOTDIR=\"\$(dirname \"\$(dirname \"\$(PWD)\")\")\"|' bin/start
            tar -czf $out_file .
        "
            echo (set_color green)"OK"(set_color normal)
            
            set url "https://github.com/Lorenzo-SF/Batamanta---ERTS-repository/releases/download/$v_tag/$filename"
            jq --arg v "$v_tag" --arg k "darwin-arm64" --arg u "$url" '.[$v][$k] = $u | if .[$v] == null then .[$v] = {($k): $u} else . end' $manifest > tmp.json && mv tmp.json $manifest
            
            git add $manifest
            git commit -m "feat: add darwin-arm64 to $v_tag in MANIFEST.json"
            git push origin main >/dev/null 2>&1

            if not gh release view $v_tag >/dev/null 2>&1
                echo "  📦 Creando Release $v_tag..."
                gh release create $v_tag --title "Erlang/OTP $v" --notes "Automated builds for OTP $v"
            end
            
            echo "  ☁️  Subiendo $filename..."
            gh release upload $v_tag $out_file --clobber
            rm -f $out_file
        else
            echo (set_color red)"FAIL"(set_color normal)
            rm -f $out_file
        end
        rm -rf $build_dir "$src_temp/opt_erlang" "$src_temp/otp_src_$v.tar.gz"
    end
    rm -rf $src_temp
    echo (set_color --bold green)"\n🏁 PROCESO darwin-arm64 COMPLETADO"(set_color normal)
end

build_darwin