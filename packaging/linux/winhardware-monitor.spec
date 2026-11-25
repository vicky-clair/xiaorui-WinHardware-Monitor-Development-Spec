# WinHardware Monitor — RPM 打包规范文件（支持 Fedora / RHEL / CentOS / Rocky / openSUSE x86_64）
%global debug_package %{nil}

Name:           winhardware-monitor
Version:        %{?_pkg_version}%{!?_pkg_version:0.1.0}
Release:        1%{?dist}
Summary:        Lightweight hardware temperature, disk SMART health monitor and benchmark tool

License:        Apache-2.0
URL:            https://github.com/vicky-clair/xiaorui-WinHardware-Monitor-Development-Spec

ExclusiveArch:  x86_64
Recommends:     libGL, libX11, libXrandr, libXinerama, libXcursor, libXi

%description
WinHardware Monitor is a lightweight, zero-driver hardware temperature,
NVMe/ATA/SAT SMART disk health monitoring (21 registered rules), and
hardware stability/benchmark tool supporting both Desktop GUI (OpenGL 3.3)
and Headless CLI modes (--cli / --info / --bench).

%install
rm -rf %{buildroot}
install -Dm755 %{_bin_path} %{buildroot}/usr/bin/winhardware-monitor
install -Dm644 %{_src_root}/packaging/linux/winhardware-monitor.desktop %{buildroot}/usr/share/applications/winhardware-monitor.desktop
install -Dm644 %{_src_root}/config/default.toml %{buildroot}/usr/share/winhardware-monitor/config/default.toml
install -Dm644 %{_src_root}/data/drive_attributes.toml %{buildroot}/usr/share/winhardware-monitor/data/drive_attributes.toml
install -Dm644 %{_src_root}/LICENSE %{buildroot}/usr/share/doc/winhardware-monitor/LICENSE
install -Dm644 %{_src_root}/README.md %{buildroot}/usr/share/doc/winhardware-monitor/README.md
install -Dm644 %{_src_root}/CHANGELOG.md %{buildroot}/usr/share/doc/winhardware-monitor/CHANGELOG.md

%files
%license /usr/share/doc/winhardware-monitor/LICENSE
%doc /usr/share/doc/winhardware-monitor/README.md
%doc /usr/share/doc/winhardware-monitor/CHANGELOG.md
/usr/bin/winhardware-monitor
/usr/share/applications/winhardware-monitor.desktop
/usr/share/winhardware-monitor/config/default.toml
/usr/share/winhardware-monitor/data/drive_attributes.toml

%changelog
* Sat Nov 21 2026 WinHardware Monitor Contributors <noreply@example.com> - 0.1.0-1
- Initial Linux x86_64 GUI + CLI release with hwmon, NVMe/SG_IO SAT SMART, 21 health rules, and benchmark suite.
