############## horcm-utils.spec ###################
%define rpmrelease %{nil}
%define BCdir usr/local/sbin

Summary: HORCM Utilities for Linux
Name: horcm-utils
Version: 1.0
Release: 1%{?rpmrelease}%{?dist}
License: GPLv3
Group: Applications/File
URL: https://github.com/gdha/horcm-utils
BuildArch: noarch

Source: https://build.opensuse.org/package/show/home:gdha/%{name}/%{name}-%{version}.tar.gz
BuildRoot: %(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)

Requires: ksh

%description
horcm-utils contains HORCM (Business Copy) related scripts to assist in making BC on Linux systems.
See online documentation as http://horcm-utilities-documentation.readthedocs.io/en/latest/

%prep
%setup -q

%build

%install
%{__rm} -rf %{buildroot}
# create directories
mkdir -vp -m 755 %{buildroot}/%{BCdir}

# copy the scripts
cp -av %{BCdir}/BC-exec.sh %{buildroot}/%{BCdir}
cp -av %{BCdir}/PairDisplay.sh %{buildroot}/%{BCdir}
cp -av %{BCdir}/CheckHorcmConsistency.sh %{buildroot}/%{BCdir}
cp -av %{BCdir}/horcmd-initscript-rhel-script.sh %{buildroot}/%{BCdir}

%clean
%{__rm} -rf %{buildroot}

%files
%defattr(-, root, root, 0755)
/%{BCdir}/BC-exec.sh
/%{BCdir}/PairDisplay.sh
/%{BCdir}/CheckHorcmConsistency.sh
/%{BCdir}/horcmd-initscript-rhel-script.sh

%changelog
* Tue Jul 08 2016 Gratien D'haese ( gratien.dhaese at gmail.com ) 1.0-1
- Initial package.

