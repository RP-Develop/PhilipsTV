# PhilipsTV - Fhem
## PhilipsTV - Fhem Integration

PhilipsTV findet automatisch Philips TV's, kann diese steuern und zeigt weitere Informationen an.

Getestet mit 65OLED805/12

### update

`update add https://raw.githubusercontent.com/RP-Develop/PhilipsTV/main/controls_PhilipsTV.txt`

## Voraussetzung: 

Folgende Libraries sind notwendig für dieses Modul:

- JSON
- Digest::MD5
- MIME::Base64
- HTML::Entities
- Data::Dumper
- LWP::UserAgent
- LWP::Protocol::https
- HTTP::Request


## 78_MagentaTV.pm

`define <name> PhilipsTV`

Beispiel: `define PhilipsTVs PhilipsTV`

Nach ca. 2 Minuten sollten alle TV's gefunden und unter "PhilipsTV" gelistet sein.

Die Hilfe zu weiteren Funktionen, ist nach Installation in der Commandref zu finden. 

