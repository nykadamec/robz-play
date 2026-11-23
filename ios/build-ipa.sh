#!/usr/bin/env bash
# Build an unsigned native iOS / iPadOS .ipa package for Robz Play (sideload-ready).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build-ios"
APP_DIR="${BUILD_DIR}/Payload/RobzPlay.app"
OBJ_DIR="${BUILD_DIR}/obj"
IPA_OUT="${ROOT_DIR}/RobzPlay-iOS-unsigned.ipa"

CLANG="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
CLANGXX="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
IOS_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.2.sdk"
if [ ! -d "${IOS_SDK}" ]; then
	IOS_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
fi

TARGET_FLAGS="-target arm64-apple-ios16.0 -isysroot ${IOS_SDK}"
COMMON_INCLUDES=(
	"-I${ROOT_DIR}/ios/include"
	"-I${ROOT_DIR}/lib/include"
	"-I${BUILD_DIR}/include"
	"-I${BUILD_DIR}/protobuf"
	"-I${ROOT_DIR}/lib/src"
	"-I${ROOT_DIR}/third-party/nanopb"
	"-I${ROOT_DIR}/third-party/jerasure/include"
	"-I${ROOT_DIR}/third-party/gf-complete/include"
	"-I${ROOT_DIR}/robzfg/include"
	"-I${ROOT_DIR}/robzfg/src"
)

rm -rf "${BUILD_DIR}"
mkdir -p "${APP_DIR}/models" "${OBJ_DIR}" "${BUILD_DIR}/include/chiaki" "${BUILD_DIR}/protobuf"

cat > "${BUILD_DIR}/include/chiaki/config.h" << 'EOF'
#ifndef CHIAKI_CONFIG_H
#define CHIAKI_CONFIG_H
/* #undef CHIAKI_LIB_ENABLE_OPUS */
/* #undef CHIAKI_LIB_ENABLE_FFMPEG_DECODER */
/* #undef CHIAKI_LIB_ENABLE_PI_DECODER */
#endif
EOF

if [ -f "${ROOT_DIR}/build/lib/protobuf/takion.pb.c" ] && [ -f "${ROOT_DIR}/build/lib/protobuf/takion.pb.h" ]; then
	cp "${ROOT_DIR}/build/lib/protobuf/takion.pb.c" "${BUILD_DIR}/protobuf/"
	cp "${ROOT_DIR}/build/lib/protobuf/takion.pb.h" "${BUILD_DIR}/protobuf/"
else
	python3 "${ROOT_DIR}/third-party/nanopb/generator/nanopb_generator.py" \
		-D "${BUILD_DIR}/protobuf" -I "${ROOT_DIR}/lib/protobuf" "${ROOT_DIR}/lib/protobuf/takion.proto"
fi

echo "==> Compiling chiaki-lib + nanopb + jerasure + gf-complete for arm64-apple-ios..."

C_SOURCES=(
	"${ROOT_DIR}/ios/src/ios_openssl_shim.c"
	"${BUILD_DIR}/protobuf/takion.pb.c"
	"${ROOT_DIR}/third-party/nanopb/pb_common.c"
	"${ROOT_DIR}/third-party/nanopb/pb_decode.c"
	"${ROOT_DIR}/third-party/nanopb/pb_encode.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_wgen.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_w4.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_w8.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_w16.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_w32.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_w64.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_w128.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_rand.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_general.c"
	"${ROOT_DIR}/third-party/gf-complete/src/gf_cpu.c"
	"${ROOT_DIR}/third-party/jerasure/src/galois.c"
	"${ROOT_DIR}/third-party/jerasure/src/jerasure.c"
	"${ROOT_DIR}/third-party/jerasure/src/reed_sol.c"
	"${ROOT_DIR}/third-party/jerasure/src/cauchy.c"
	"${ROOT_DIR}/third-party/jerasure/src/liberation.c"
	"${ROOT_DIR}/lib/src/audio.c"
	"${ROOT_DIR}/lib/src/audioreceiver.c"
	"${ROOT_DIR}/lib/src/audiosender.c"
	"${ROOT_DIR}/lib/src/base64.c"
	"${ROOT_DIR}/lib/src/bitstream.c"
	"${ROOT_DIR}/lib/src/common.c"
	"${ROOT_DIR}/lib/src/congestioncontrol.c"
	"${ROOT_DIR}/lib/src/controller.c"
	"${ROOT_DIR}/lib/src/ctrl.c"
	"${ROOT_DIR}/lib/src/discovery.c"
	"${ROOT_DIR}/lib/src/discoveryservice.c"
	"${ROOT_DIR}/lib/src/ecdh.c"
	"${ROOT_DIR}/lib/src/fec.c"
	"${ROOT_DIR}/lib/src/feedback.c"
	"${ROOT_DIR}/lib/src/feedbacksender.c"
	"${ROOT_DIR}/lib/src/frameprocessor.c"
	"${ROOT_DIR}/lib/src/gkcrypt.c"
	"${ROOT_DIR}/lib/src/http.c"
	"${ROOT_DIR}/lib/src/launchspec.c"
	"${ROOT_DIR}/lib/src/log.c"
	"${ROOT_DIR}/lib/src/orientation.c"
	"${ROOT_DIR}/lib/src/packetstats.c"
	"${ROOT_DIR}/lib/src/random.c"
	"${ROOT_DIR}/lib/src/regist.c"
	"${ROOT_DIR}/lib/src/reorderqueue.c"
	"${ROOT_DIR}/lib/src/rpcrypt.c"
	"${ROOT_DIR}/lib/src/senkusha.c"
	"${ROOT_DIR}/lib/src/session.c"
	"${ROOT_DIR}/lib/src/sock.c"
	"${ROOT_DIR}/lib/src/stoppipe.c"
	"${ROOT_DIR}/lib/src/streamconnection.c"
	"${ROOT_DIR}/lib/src/takion.c"
	"${ROOT_DIR}/lib/src/takionsendbuffer.c"
	"${ROOT_DIR}/lib/src/thread.c"
	"${ROOT_DIR}/lib/src/time.c"
	"${ROOT_DIR}/lib/src/videoreceiver.c"
	"${ROOT_DIR}/lib/src/remote/rudp.c"
	"${ROOT_DIR}/lib/src/remote/rudpsendbuffer.c"
)

OBJS=()
idx=0
for src in "${C_SOURCES[@]}"; do
	obj="${OBJ_DIR}/c_${idx}_$(basename "${src}" .c).o"
	"${CLANG}" ${TARGET_FLAGS} -O3 -DPB_C99_STATIC_ASSERT -DCHIAKI_VERSION=\"1.10.1\" -DROBZPLAY_VERSION=\"0.4.1\" \
		"${COMMON_INCLUDES[@]}" -c "${src}" -o "${obj}"
	OBJS+=("${obj}")
	idx=$((idx + 1))
done

echo "==> Compiling robzfg (Apple Metal + MPSGraph RIFE engine) & native iOS UI..."

"${CLANGXX}" ${TARGET_FLAGS} -std=c++17 -O3 "${COMMON_INCLUDES[@]}" \
	-c "${ROOT_DIR}/robzfg/src/dedup.cpp" -o "${OBJ_DIR}/dedup.o"
OBJS+=("${OBJ_DIR}/dedup.o")

"${CLANGXX}" ${TARGET_FLAGS} -std=c++17 -O3 -fobjc-arc "${COMMON_INCLUDES[@]}" \
	-c "${ROOT_DIR}/robzfg/src/rife_metal.mm" -o "${OBJ_DIR}/rife_metal.o"
OBJS+=("${OBJ_DIR}/rife_metal.o")

"${CLANGXX}" ${TARGET_FLAGS} -std=c++17 -O3 -fobjc-arc "${COMMON_INCLUDES[@]}" \
	-c "${ROOT_DIR}/ios/src/RobzPlayIOSApp.mm" -o "${OBJ_DIR}/RobzPlayIOSApp.o"
OBJS+=("${OBJ_DIR}/RobzPlayIOSApp.o")

echo "==> Linking Mach-O arm64 iOS executable..."
"${CLANGXX}" ${TARGET_FLAGS} -fobjc-arc "${OBJS[@]}" \
	-framework UIKit \
	-framework Foundation \
	-framework Metal \
	-framework MetalKit \
	-framework MetalPerformanceShaders \
	-framework MetalPerformanceShadersGraph \
	-framework VideoToolbox \
	-framework CoreMedia \
	-framework CoreVideo \
	-framework GameController \
	-framework QuartzCore \
	-framework Security \
	-o "${APP_DIR}/RobzPlay"

echo "==> Bundling Info.plist and RIFE models (rife_v4_6 & rife_v4_25_lite)..."
cp "${ROOT_DIR}/ios/Info.plist" "${APP_DIR}/Info.plist"
printf "APPL????" > "${APP_DIR}/PkgInfo"
mkdir -p "${APP_DIR}/models/rife_v4_6"
cp "${ROOT_DIR}/robzfg/models/rife-v4.6/flownet.param" "${ROOT_DIR}/robzfg/models/rife-v4.6/flownet.bin" "${APP_DIR}/models/rife_v4_6/"
if [ -d "${ROOT_DIR}/robzfg/models/rife-v4.25-lite" ]; then
	mkdir -p "${APP_DIR}/models/rife_v4_25_lite"
	cp "${ROOT_DIR}/robzfg/models/rife-v4.25-lite/flownet.param" "${ROOT_DIR}/robzfg/models/rife-v4.25-lite/flownet.bin" "${APP_DIR}/models/rife_v4_25_lite/"
fi

echo "==> Applying ad-hoc bundle signature structure for iOS sideloaders..."
codesign --force --sign - "${APP_DIR}" || true

echo "==> Packaging unsigned .ipa for sideloading..."
rm -f "${IPA_OUT}"
(cd "${BUILD_DIR}" && zip -qry "${IPA_OUT}" Payload)

echo "==> Done! Unsigned IPA created at: ${IPA_OUT}"
ls -lh "${IPA_OUT}" "${APP_DIR}/RobzPlay"
file "${APP_DIR}/RobzPlay"
