# Third-party components / Drittkomponenten

The WBCE Portable **release ZIP** bundles the following independent programs.
They are separate works that are merely distributed together (aggregation); each keeps
its own license. The MIT license of this repository (`LICENSE`) covers only the
build scripts and the launcher source code in this repository.

| Component | Version | License | Source |
|---|---|---|---|
| Apache HTTP Server (Apache Lounge Windows build) | 2.4.69 | Apache License 2.0 | https://httpd.apache.org/ · binaries: https://www.apachelounge.com/ |
| PHP (Windows build, thread safe) | 8.3.36 | PHP License 3.01 | https://www.php.net/ · https://github.com/php/php-src |
| MariaDB Server | 11.4.13 | GPL-2.0 (see `LICENSE-MariaDB.txt`) | https://archive.mariadb.org/mariadb-11.4.13/source/ · https://github.com/MariaDB/server |
| WBCE CMS | 1.6.9 | GPL-2.0-or-later (see `LICENSE-WBCE.txt`) | https://github.com/WBCE/WBCE_CMS (tag `1.6.9`) |
| Adminer | 4.8.1 | Apache License 2.0 or GPL-2.0 | https://github.com/vrana/adminer |
| WBCE-Portable.exe launcher | this repo | MIT | `launcher/` in this repo; built with Free Pascal 3.2.2 / Lazarus (LCL and RTL: LGPL with static-linking exception) |

The release ZIP also contains the unmodified, Microsoft-signed installer
`vcredist/vc_redist.x64.exe` (Microsoft Visual C++ Redistributable, x64), which the
launcher offers to install when the runtime is missing (the signature is verified
before it is run). It is distributed under Microsoft's license terms for
redistributable code (https://aka.ms/vc14/vc_redist.x64.exe) and is **not** covered by
the MIT license of this repository.

## Source code offer (GPL-2.0 components)

MariaDB and WBCE CMS are distributed in binary and/or source form under the GPL-2.0.
The complete corresponding source code of the exact versions bundled here is available
from the upstream links in the table above. On request (open an issue in this
repository) the maintainer will additionally provide the corresponding source for
at least three years after the release.

## Hinweis (Deutsch)

Die Release-ZIP enthaelt die oben genannten, voneinander unabhaengigen Programme
(blosse Zusammenstellung / "mere aggregation"). Jedes behaelt seine eigene Lizenz;
die MIT-Lizenz dieses Repositories gilt nur fuer die Build-Skripte und den
Launcher-Quellcode. Den Quellcode der GPL-Komponenten (MariaDB, WBCE) gibt es unter
den oben verlinkten Upstream-Adressen in genau den gebuendelten Versionen.
