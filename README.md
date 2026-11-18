<h1 align="center">Linux CAC</h1>

<p align='center'>
  <a href="https://github.com/sponsors/jdjaxon"><img alt="Sponsor" src="https://img.shields.io/badge/sponsor-30363D?style=flat&logo=GitHub-Sponsors&logoColor=#white" /></a>
  &nbsp;
  <a href="https://github.com/jcfurey/linux_cac"><img alt="GitHub Repo stars" src="https://img.shields.io/github/stars/jcfurey/linux_cac?style=flat&labelColor=30363D&color=gray" /></a>
  &nbsp;
  <a href="https://github.com/jcfurey/linux_cac/actions/workflows/CI.yml"><img alt="CI" src="https://github.com/jcfurey/linux_cac/actions/workflows/CI.yml/badge.svg?" /></a>
</p>

A project for configuring Linux distributions to work with Common Access Cards
(CACs). Supports Debian/Ubuntu, Fedora/RHEL/CentOS, and Arch Linux. On
Debian-family systems, this fork configures native Firefox and can migrate a
Firefox snap installation to the apt version. See [Known Issues](#known-issues)
for migration details.

> [!note]
> This project has moved from using Cackey to OpenSC, which seems to be
> more stable. If you previously installed Cackey, you can remove it:
> - Debian/Ubuntu: `sudo apt purge cackey`
> - Fedora/RHEL: `sudo dnf remove cackey`
> - Arch: `sudo pacman -R cackey`

## Table of Contents
<details>
<summary>
<b>Click to Toggle Expansion</b>
</summary>

1. [Supported Configurations](#supported-configurations)
1. [Installation](#installation)
   1. [Methods](#methods)
1. [Known Issues](#known-issues)
1. [Troubleshooting](#troubleshooting)
    1. [Microsoft Teams](#microsoft-teams)
1. [License](#license)
1. [References](#references)

</details>


## Supported Configurations

Regardless of how similar two distributions may be, I will only list
distributions and versions here that I know have been tested with this method.
This fork supports native Firefox packages, including Firefox ESR.

| Family | Distribution | Versions | Browsers |
| :-: | :-: | :-: | :-: |
| Debian | Debian | 12.5 | Firefox ESR, Chrome, Edge |
| | Mint | 21.2 | Firefox, Chrome |
| | Parrot OS | 6.0.0-2 | Firefox, Brave |
| | PopOS! | 20.04 LTS, 22.04 LTS | Firefox, Chrome |
| | Ubuntu | 20.04 LTS, 22.04 LTS | Firefox, Chrome |
| Fedora | Fedora, RHEL, CentOS | — | Firefox, Chrome |
| Arch | Arch Linux | — | Firefox, Chrome |

> [!note]
> Fedora/RHEL/CentOS and Arch Linux are supported via auto-detection but
> have had limited community testing. There are also reports of this script
> working with other distributions and browsers not listed above.


## Installation
> [!warning]
>  Please make sure all browsers are closed before running the script.

Run the installer with `sudo` from your regular desktop account. It installs
OpenSC and starts the smart-card service with root privileges. It imports
certificates and registers OpenSC in browser databases as your desktop user.
You can review the [installer in this fork](./cac_setup.sh) and the
[certificate bundle from MilitaryCAC](https://militarycac.com/maccerts/AllCerts.zip).

> [!note]
> - The automated installation requires `wget` and `unzip` to run and will
>  install both during the setup if they are not already installed. If you don't
>  want either tool, remove it after the setup is complete using your package
>  manager (e.g., `sudo apt remove <command>`, `sudo dnf remove <command>`, or
>  `sudo pacman -R <command>`).
> - The scripted installation has only been tested on the configurations listed in the
>  [Supported Configurations](#supported-configurations)


#### Methods

From a checkout of this fork, run `sudo bash ./cac_setup.sh`. To download the
installer from the fork's `main` branch, run either command in an empty directory.

```bash
wget -O cac_setup.sh https://raw.githubusercontent.com/jcfurey/linux_cac/main/cac_setup.sh && sudo bash ./cac_setup.sh
```

```bash
curl -fsSLo cac_setup.sh https://raw.githubusercontent.com/jcfurey/linux_cac/main/cac_setup.sh && sudo bash ./cac_setup.sh
```

## Known Issues
- The CAC PKCS#11 module is loaded directly into each detected browser's NSS
  database (both Firefox-family and Chromium-family). If a browser still does
  not prompt for your PIN after setup, make sure it is fully closed (including
  background processes) and reboot, then try again.

- Setup initializes the shared Chromium NSS database and registers each Firefox
  profile listed in `profiles.ini`. If Firefox cannot create its initial profile
  headlessly, start it once, close it, and rerun setup.

- On Debian-family systems with snap Firefox, you can keep the snap and configure another
  installed browser, or opt into replacing it with native Firefox from the
  Mozilla Team PPA. Automatic transfer supports a single source profile. If
  migration fails after backup, the installer prints the backup directory.

- If you run into any issues with Firefox after running the script, clear your
  data and history in `Privacy & Security` and then restart Firefox. If your
  troubles are with MS Teams, see the section for [troubleshooting
  teams](#microsoft-teams). Microsoft lists the supported Linux browsers in its
  [Teams for Web requirements](https://learn.microsoft.com/en-us/microsoftteams/teams-client-web).

- Firefox will likely start up a bit slower after running this installation.


## Troubleshooting
### Microsoft Teams
If you run into issues with MS Teams, try the following steps:
1. In the Firefox Settings window, select the `Privacy & Security` tab
2. Under `Cookies and Site Data`, select `Manage Exceptions`
3. In the `Address of website` text box, enter the following URLs, and then select `Allow`
    ```
    https://microsoft.com
    https://microsoftonline.com
    https://teams.skype.com
    https://teams.microsoft.com
    https://sfbassets.com
    https://skypeforbusiness.com
    ```
4. Select `Save Changes`

> [!note]
> `strict` security settings in Firefox may cause a loading loop

See the official documentation for this issue
[here](https://docs.microsoft.com/en-us/microsoftteams/troubleshoot/teams-sign-in/sign-in-loop#mozilla-firefox).


## Contributing
Thank you for your interest in contributing to **linux_cac**! Whether you're fixing a bug, improving documentation, or adding a new feature, your help is appreciated.

### How to Contribute
1. **Fork the repository**
   Create your own copy of the project by clicking the "Fork" button at the top right of this page.

2. **Clone your fork**
   ```
   git clone https://github.com/YOUR_USERNAME/linux_cac.git
   cd linux_cac
   ```

3. **Create a branch for your changes**
   ```
   git checkout -b <your-branch-name>
   ```
   OR
   ```
   git switch -c <your-branch-name>
   ```

5. **Make your changes**
   Keep commits focused and meaningful. Update or add documentation if needed.

6. **Test your changes**

   Run `shellcheck -x cac_setup.sh tests/setup.sh` and `bash tests/setup.sh`.
   The tests use temporary profiles, NSS tools, OpenSC, OpenSSL, zip, and unzip.
   They run as your regular user without a CAC reader.

7. **Push to your fork and open a Pull Request**
   ```
   git push origin <your-branch-name>
   ```
   Then, open a Pull Request on GitHub against the `main` branch of this repository.

### Guidelines
- Follow existing code style and conventions.
- Keep changes atomic and well-documented in commit messages.

### Need Help?
For fork changes, open a [pull request against jcfurey/linux_cac](https://github.com/jcfurey/linux_cac/pulls).
Shared browser and distribution issues are tracked in the [upstream issue tracker](https://github.com/jdjaxon/linux_cac/issues).


## License
This project is licensed under the MIT License.
See the [LICENSE](./LICENSE) file for details.

> [!warning]
> This software is provided as-is without any warranty.
> Use it at your own risk, especially in sensitive or production environments.
> Always review scripts before running them.



## References
- https://militarycac.com/linux.htm (this was my starting point)
- https://chromium.googlesource.com/chromium/src.git/+/refs/heads/main/docs/linux/cert_management.md
- https://firefox-source-docs.mozilla.org/security/nss/legacy/tools/nss_tools_certutil/index.html
- https://firefox-source-docs.mozilla.org/security/nss/legacy/tools/certutil/index.html
- https://askubuntu.com/questions/244582/add-certificate-authorities-system-wide-on-firefox
- https://stackoverflow.com/questions/1435000/programmatically-install-certificate-into-mozilla
- https://docs.microsoft.com/en-us/microsoftteams/troubleshoot/teams-sign-in/sign-in-loop#mozilla-firefox
