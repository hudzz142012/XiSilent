#!/bin/bash
# .start.sh - auto-generated oleh installer egg NodeJS CMD_RUN v10
cd /home/container || exit 1

mkdir -p bin im/bin im/lib .npm-global .local-bin

IS_ROOT=0
[ "$(id -u)" = "0" ] && IS_ROOT=1

IM_VER="7.1.2-30"
IM_ENV="LD_LIBRARY_PATH=/home/container/im/lib MAGICK_HOME=/home/container/im"

im_ok() {
    env $IM_ENV ./im/bin/magick --version >/dev/null 2>&1
}

# 1. APT HANYA kalau root (container Ptero umumnya non-root)
if [ "$IS_ROOT" = "1" ] && { ! command -v ffmpeg >/dev/null 2>&1 || ! command -v cwebp >/dev/null 2>&1 || ! command -v magick >/dev/null 2>&1; }; then
    echo "[STARTUP] Installing system packages (root)..."
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg imagemagick webp fonts-liberation $APT_PACKAGES 2>&1 | tail -n 3
fi

# 2. FFMPEG STATIC (fallback tanpa root) - juga di folder server, bukan /tmp
if ! command -v ffmpeg >/dev/null 2>&1 && [ ! -x bin/ffmpeg ]; then
    echo "[STARTUP] Downloading ffmpeg static (~80MB, sekali saja)..."
    mkdir -p ff-tmp
    curl -sL --retry 2 --max-time 600 https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz -o ff-tmp/ff.txz \
        && tar xJf ff-tmp/ff.txz -C bin --strip-components=1 --wildcards '*/ffmpeg' '*/ffprobe' \
        && chmod +x bin/ffmpeg bin/ffprobe \
        && echo "[STARTUP] ffmpeg static OK" \
        || echo "[STARTUP] WARNING: download ffmpeg gagal"
    rm -rf ff-tmp
fi

# 3. WEBP STATIC - di folder server
if ! command -v cwebp >/dev/null 2>&1 && [ ! -x bin/cwebp ]; then
    echo "[STARTUP] Downloading libwebp static..."
    mkdir -p webp-tmp
    curl -sL --retry 2 --max-time 300 https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0-linux-x86-64.tar.gz -o webp-tmp/webp.tgz \
        && tar xzf webp-tmp/webp.tgz -C bin --strip-components=2 libwebp-1.4.0-linux-x86-64/bin/cwebp libwebp-1.4.0-linux-x86-64/bin/dwebp libwebp-1.4.0-linux-x86-64/bin/gif2webp \
        && chmod +x bin/cwebp bin/dwebp bin/gif2webp \
        && echo "[STARTUP] webp OK" \
        || echo "[STARTUP] WARNING: download webp gagal"
    rm -rf webp-tmp
fi

# 4. IMAGEMAGICK 7 - download & extract di FOLDER SERVER (bukan /tmp!)
# /tmp di container Pterodactyl = tmpfs kecil -> extract 180MB pasti terputus
if ! command -v magick >/dev/null 2>&1 && ! im_ok; then
    for ATTEMPT in 1 2 3; do
        case $ATTEMPT in
            1|3) VARIANT=gcc ;;
            2)   VARIANT=clang ;;
        esac
        echo "[STARTUP] ImageMagick: percobaan $ATTEMPT/3 (${VARIANT} build)..."
        rm -rf im extract-tmp
        mkdir -p im/bin im/lib extract-tmp

        # Download langsung ke folder server
        curl -sL --retry 2 --max-time 900 "https://github.com/ImageMagick/ImageMagick/releases/download/${IM_VER}/ImageMagick-${IM_VER}-${VARIANT}-x86_64.AppImage" -o extract-tmp/im.AppImage
        SIZE=$(stat -c%s extract-tmp/im.AppImage 2>/dev/null || echo 0)
        if [ "$SIZE" -lt 30000000 ]; then
            echo "[STARTUP] Download korup/truncated (${SIZE} bytes < 30MB) - retry"
            rm -rf extract-tmp
            continue
        fi
        chmod +x extract-tmp/im.AppImage

        # Extract DI FOLDER SERVER
        ( cd extract-tmp && ./im.AppImage --appimage-extract >/dev/null 2>&1 )
        if [ ! -x extract-tmp/squashfs-root/usr/bin/magick ]; then
            echo "[STARTUP] Extract gagal - retry"
            rm -rf extract-tmp
            continue
        fi

        # Binaries (kecil)
        cp -L extract-tmp/squashfs-root/usr/bin/* im/bin/ 2>/dev/null

        # SMART LIB COPY: hanya lib yang missing via ldd, iteratif
        ROUND=0
        while [ $ROUND -lt 8 ]; do
            ROUND=$((ROUND+1))
            MISSING=$(env LD_LIBRARY_PATH=/home/container/im/lib ldd im/bin/magick 2>/dev/null | awk '/not found/{print $1}' | sort -u)
            [ -z "$MISSING" ] && break
            COPIED=0
            for M in $MISSING; do
                SRC=$(find extract-tmp/squashfs-root/usr/lib -name "$M" 2>/dev/null | head -n1)
                if [ -n "$SRC" ]; then
                    cp -L "$SRC" im/lib/
                    COPIED=$((COPIED+1))
                fi
            done
            if [ $COPIED -eq 0 ]; then
                echo "[STARTUP] WARNING: lib tidak ditemukan di paket: $(echo $MISSING | tr '\n' ' ')"
                break
            fi
        done

        rm -f im/lib/*.a im/lib/*.la
        rm -rf extract-tmp

        # Deteksi file 0-byte
        ZEROS=$(find im -type f -size 0 2>/dev/null | head -n 3)
        if [ -n "$ZEROS" ]; then
            echo "[STARTUP] WARNING: ada file 0-byte ($ZEROS) - retry dengan varian lain"
        fi

        if im_ok; then
            break
        else
            echo "[STARTUP] magick masih gagal jalan - coba varian lain..."
        fi
    done
fi

# Status akhir ImageMagick
if command -v magick >/dev/null 2>&1; then
    echo "[STARTUP] ImageMagick: pakai versi sistem ($(magick --version 2>/dev/null | head -n1 | awk '{print $2}'))"
elif [ -x im/bin/magick ] && im_ok; then
    echo "[STARTUP] ImageMagick OK ($(env $IM_ENV ./im/bin/magick --version | head -n1 | awk '{print $2}')) - $(du -sh im 2>/dev/null | awk '{print $1}')"
elif [ -x im/bin/magick ]; then
    echo "[STARTUP] WARNING: ImageMagick terpasang tapi gagal jalan."
    echo "[STARTUP] Lib kurang:"
    env $IM_ENV ldd im/bin/magick 2>&1 | grep 'not found' | head -5 || true
else
    echo "[STARTUP] WARNING: ImageMagick tidak tersedia."
fi

# 5. PM2 LOKAL (tidak butuh root)
if ! command -v pm2 >/dev/null 2>&1 && [ ! -x .npm-global/bin/pm2 ]; then
    echo "[STARTUP] Installing pm2 (lokal)..."
    npm install -g --prefix .npm-global pm2@latest --no-audit --no-fund >/dev/null 2>&1 \
        && echo "[STARTUP] pm2 OK" \
        || echo "[STARTUP] WARNING: pm2 gagal diinstall"
fi

# 6. GIT AUTO CLONE / PULL SETIAP START
# Catatan: tools (im/, bin/, dst.) dipasang LEBIH DULU, jadi folder tidak pernah
# kosong. Clone ke "." akan selalu gagal -> makanya clone masuk .deploy-tmp dulu.
if [ -n "$GIT_ADDRESS" ]; then
    GA="$GIT_ADDRESS"
    case "$GA" in *.git) ;; *) GA="$GA.git" ;; esac
    if [ -n "$USERNAME" ] || [ -n "$ACCESS_TOKEN" ]; then
        GA="https://$USERNAME:$ACCESS_TOKEN@$(echo "$GA" | cut -d/ -f3-)"
    fi
    CLONE_ARGS="--depth 1"
    if [ -n "$BRANCH" ]; then
        CLONE_ARGS="$CLONE_ARGS --single-branch --branch $BRANCH"
    fi
    if [ -d .git ]; then
        echo "[STARTUP] Pulling latest from git..."
        git pull || echo "[STARTUP] WARNING: git pull gagal, lanjut pakai file yang ada"
    elif ls package.json index.js app.js main.js bot.js src config.json >/dev/null 2>&1; then
        echo "[STARTUP] Folder sudah berisi project (tanpa .git) - clone dilewati."
        echo "[STARTUP] Pakai upload manual? Kosongkan variable GIT_ADDRESS di tab Startup."
    else
        echo "[STARTUP] Cloning repo..."
        rm -rf .deploy-tmp
        if git clone $CLONE_ARGS "$GA" .deploy-tmp; then
            shopt -s dotglob nullglob
            for f in .deploy-tmp/*; do
                cp -a "$f" . 2>/dev/null
            done
            shopt -u dotglob nullglob
            rm -rf .deploy-tmp
            echo "[STARTUP] Clone OK"
        else
            echo "[STARTUP] WARNING: clone gagal (cek URL repo / token / koneksi)"
        fi
        rm -rf .deploy-tmp
    fi
fi

# 7. NPM INSTALL
if [ -f package.json ]; then
    echo "[STARTUP] Running npm install..."
    npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1
fi
if [ -n "$NODE_PACKAGES" ]; then
    echo "[STARTUP] Installing extra npm packages..."
    npm install $NODE_PACKAGES --no-audit --no-fund >/dev/null 2>&1
fi

# 8. WRAPPER ImageMagick (env per-command, BUKAN global)
for tool in magick convert identify compare composite animate conjure import stream display mogrify montage; do
    if [ -x im/bin/$tool ]; then
        cat > .local-bin/$tool << WRAPEOF
#!/bin/bash
export LD_LIBRARY_PATH="/home/container/im/lib:\$LD_LIBRARY_PATH"
export MAGICK_HOME="/home/container/im"
exec /home/container/im/bin/$tool "\$@"
WRAPEOF
        chmod +x .local-bin/$tool
    fi
done
export PATH="/home/container/.local-bin:/home/container/bin:/home/container/.npm-global/bin:$PATH"

echo "[STARTUP] Starting: $CMD_RUN"
exec bash -c "$CMD_RUN"
