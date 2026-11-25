#!/usr/bin/env bash
# WinHardware Monitor — Linux x86_64 一键测试、构建与多格式打包脚本
# 产出：.tar.gz（便携版）、.deb（Debian/Ubuntu）、.rpm（Fedora/RHEL/CentOS/Rocky/openSUSE）及 SHA256SUMS.txt
set -euo pipefail

VERSION="${VERSION:-0.1.0}"
ZIG_BIN="${ZIG_BIN:-zig}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist-linux"

cd "${REPO_ROOT}"

echo "=== [1/6] 运行 Zig 单元测试、Debug 与通用 Linux ReleaseSafe (-Dtarget=x86_64-linux-gnu.2.17 -Dcpu=baseline) 构建 ==="
"${ZIG_BIN}" build test
"${ZIG_BIN}" build
# 强制锁定 GLIBC 2.17 + x86-64 baseline（SSE2），确保单一二进制兼容 CentOS 7 / RHEL 8-9 / Debian 10-13 / Ubuntu 18.04-24.04 / Fedora / openSUSE / Arch / 麒麟 / UOS 等所有主流 x86_64 glibc 发行版
"${ZIG_BIN}" build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.17 -Dcpu=baseline

BIN_PATH="${REPO_ROOT}/zig-out/bin/winhardware-monitor"
chmod +x "${BIN_PATH}"
if command -v strip >/dev/null 2>&1; then
  strip --strip-unneeded "${BIN_PATH}" || true
fi
mkdir -p "${DIST_DIR}"

echo "=== [2/6] 校验 ELF 兼容性（GLIBC 版本 / 动态库）并执行无界面 CLI 真实硬件采集自检 ==="
if command -v readelf >/dev/null 2>&1; then
  echo "--- DT_NEEDED ---"
  readelf -d "${BIN_PATH}" | grep -E 'NEEDED' || true
  echo "--- GLIBC SYMBOL VERSIONS ---"
  readelf --version-info "${BIN_PATH}" | grep -oE 'GLIBC_[0-9.]+' | sort -Vu || true
fi
"${BIN_PATH}" --cli

echo "=== [3/6] 打包便携版 .tar.gz ==="
PORTABLE_NAME="winhardware-monitor-${VERSION}-linux-x86_64-portable"
PORTABLE_STAGE="${DIST_DIR}/${PORTABLE_NAME}"
rm -rf "${PORTABLE_STAGE}" "${DIST_DIR}/${PORTABLE_NAME}.tar.gz"
mkdir -p "${PORTABLE_STAGE}/config" "${PORTABLE_STAGE}/data" "${PORTABLE_STAGE}/docs"
cp "${BIN_PATH}" "${PORTABLE_STAGE}/winhardware-monitor"
touch "${PORTABLE_STAGE}/portable.flag"
cp config/default.toml "${PORTABLE_STAGE}/config/"
cp data/drive_attributes.toml "${PORTABLE_STAGE}/data/"
cp packaging/linux/winhardware-monitor.desktop "${PORTABLE_STAGE}/"
cp LICENSE README.md CHANGELOG.md "${PORTABLE_STAGE}/"
cp docs/*.md "${PORTABLE_STAGE}/docs/"
tar -C "${DIST_DIR}" -czf "${DIST_DIR}/${PORTABLE_NAME}.tar.gz" "${PORTABLE_NAME}"

echo "=== [4/6] 打包 Debian/Ubuntu .deb ==="
if command -v dpkg-deb >/dev/null 2>&1; then
  DEB_STAGE="${DIST_DIR}/deb-root"
  DEB_OUT="${DIST_DIR}/winhardware-monitor_${VERSION}_amd64.deb"
  rm -rf "${DEB_STAGE}" "${DEB_OUT}"
  mkdir -p "${DEB_STAGE}/DEBIAN" \
           "${DEB_STAGE}/usr/bin" \
           "${DEB_STAGE}/usr/share/applications" \
           "${DEB_STAGE}/usr/share/winhardware-monitor/config" \
           "${DEB_STAGE}/usr/share/winhardware-monitor/data" \
           "${DEB_STAGE}/usr/share/doc/winhardware-monitor"

  install -m 755 "${BIN_PATH}" "${DEB_STAGE}/usr/bin/winhardware-monitor"
  install -m 644 packaging/linux/winhardware-monitor.desktop "${DEB_STAGE}/usr/share/applications/"
  install -m 644 config/default.toml "${DEB_STAGE}/usr/share/winhardware-monitor/config/"
  install -m 644 data/drive_attributes.toml "${DEB_STAGE}/usr/share/winhardware-monitor/data/"
  install -m 644 LICENSE README.md CHANGELOG.md "${DEB_STAGE}/usr/share/doc/winhardware-monitor/"

  INSTALLED_KB="$(du -sk "${DEB_STAGE}/usr" | awk '{print $1}')"
  cat > "${DEB_STAGE}/DEBIAN/control" <<EOF
Package: winhardware-monitor
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: ${INSTALLED_KB}
Depends: libc6 (>= 2.17)
Recommends: libgl1, libx11-6, libxrandr2, libxinerama1, libxcursor1, libxi6
Maintainer: WinHardware Monitor Contributors <noreply@example.com>
Description: Lightweight hardware temperature, disk SMART health monitor and benchmark tool
 Supports real-time Linux hwmon temperature monitoring, NVMe/ATA/SAT SMART
 21-rule health assessment, and CPU/Memory/Disk/GPU benchmarks in both
 Desktop GUI and Headless CLI modes.
EOF

  dpkg-deb --build --root-owner-group "${DEB_STAGE}" "${DEB_OUT}"
  dpkg-deb --info "${DEB_OUT}"
else
  echo "[WARN] 未找到 dpkg-deb，跳过 .deb 打包"
fi

echo "=== [5/6] 打包 Fedora/RHEL/CentOS/openSUSE .rpm ==="
if command -v rpmbuild >/dev/null 2>&1; then
  RPM_TOP="${DIST_DIR}/rpmbuild"
  rm -rf "${RPM_TOP}"
  mkdir -p "${RPM_TOP}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
  cp packaging/linux/winhardware-monitor.spec "${RPM_TOP}/SPECS/"
  rpmbuild -bb \
    --define "_topdir ${RPM_TOP}" \
    --define "_pkg_version ${VERSION}" \
    --define "_bin_path ${BIN_PATH}" \
    --define "_src_root ${REPO_ROOT}" \
    --target x86_64 \
    "${RPM_TOP}/SPECS/winhardware-monitor.spec"
  cp "${RPM_TOP}"/RPMS/x86_64/*.rpm "${DIST_DIR}/"
  if command -v rpm >/dev/null 2>&1; then
    for r in "${DIST_DIR}"/*.rpm; do
      rpm -qip "${r}"
      rpm -qlp "${r}"
    done
  fi
else
  echo "[WARN] 未找到 rpmbuild，跳过 .rpm 打包（Debian/Ubuntu 可执行 sudo apt install rpm）"
fi

echo "=== [6/6] 生成 SHA-256 校验清单 ==="
(
  cd "${DIST_DIR}"
  rm -f SHA256SUMS.txt
  for f in *.tar.gz *.deb *.rpm; do
    [ -f "$f" ] && sha256sum "$f" >> SHA256SUMS.txt
  done
  cat SHA256SUMS.txt
)

echo "=== Linux 打包完成：${DIST_DIR} ==="
