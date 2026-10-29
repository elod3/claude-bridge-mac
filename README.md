# Claude Bridge pentru Mac

Făcut de Előd. Claude Code primește acces la un browser cu conturile tale:
deschide taburi, citește pagini, dă click, scrie în formulare, face capturi.
Browserul e **Claude Browser**: Firefox Developer Edition, pe un profil al lui,
cu extensia Claude Bridge. Nimic nu ascultă pe rețea: extensia vorbește doar
cu un program local, prin native messaging, iar Claude Code vorbește cu el
printr-un socket pe care îl poate deschide doar utilizatorul tău.

## Instalare cu Claude Code

Dă-i lui Claude Code linkul ăsta și spune-i: „instalează Claude Bridge de aici”.
Pentru Claude, comanda e:

```
git clone https://github.com/elod3/claude-bridge-mac.git ~/claude-bridge-mac && bash ~/claude-bridge-mac/install.sh
```

Instalatorul rulează singur până la capăt și termină cu „Gata, merge.” Apoi
Claude Code trebuie repornit (o sesiune nouă), ca să vadă serverul `bridge`.

## Instalare de mână (o singură dată)

1. Ia folderul: `git clone https://github.com/elod3/claude-bridge-mac.git ~/claude-bridge-mac`
   (sau Code → Download ZIP pe GitHub și dezarhivează-l în home).
2. Deschide **Terminal** și rulează:

   ```
   bash ~/claude-bridge-mac/install.sh
   ```

3. Instalatorul:
   - instalează Firefox Developer Edition dacă nu-l ai (de la Mozilla,
     verificat cu suma SHA-512 a lui Mozilla înainte să fie copiat);
   - pune extensia și bridge-ul în `~/Library/Application Support/ClaudeBridge`;
   - face aplicația **Claude Browser** în `~/Applications`;
   - îl leagă de Claude Code (serverul MCP `bridge`);
   - pornește Claude Browser și verifică singur că legătura merge.

   La final trebuie să scrie „Gata, merge.”
4. În Claude Browser intră în conturile de care ai nevoie (Gmail, WordPress etc.).
5. Repornește Claude Code. Apoi poți să-i ceri, de exemplu:
   „deschide inhabitstudio.ro/wp-admin în browser și spune-mi ce comenzi noi sunt”.

Dacă îți cere Python, rulează `xcode-select --install`, apasă Install, apoi
rulează din nou install.sh.

## De știut

- Claude vede doar Claude Browser, nu Safari sau Chrome-ul tău.
- Browserul trebuie să fie deschis când îi ceri ceva lui Claude. Dacă e închis,
  Claude primește mesajul „Claude Browser is not running” și îți spune.
- Click-urile și tastele sunt evenimente din pagină, nu mouse real: câteva
  site-uri le ignoră. Capturile aduc tabul în față.
- Update: `cd ~/claude-bridge-mac && git pull && bash install.sh`. Conturile rămân.

## Dezinstalare

```
bash ~/claude-bridge-mac/install.sh remove
```

Scoate aplicația, extensia și legătura cu Claude Code. Profilul browserului
(cu conturile) rămâne în `~/Library/Application Support/ClaudeBridge/profile`;
instalatorul îți spune cum îl ștergi dacă vrei.

## Cum e făcut

- `extension/`: extensia (Manifest V2, Firefox 128+). `background.js` primește
  cererile și le face cu API-urile WebExtension; `page.js` rulează în tab
  (citit, click, scris).
- `bridge/host.py`: programul pe care Firefox îl pornește pentru extensie;
  ține socketul `run/bridge.sock` (folder 0700, socket 0600, verifică și uid-ul).
- `bridge/mcp.py`: serverul MCP pe care îl pornește Claude Code (stdio, fără
  dependențe; Python 3.8+).
- `tests/`: testele de pe Linux (`e2e-linux.sh` rulează instalatorul cu
  comenzile de Mac simulate și toate cele 15 unelte prin MCP;
  `download-linux.sh` verifică descărcarea și suma de control a lui Mozilla).
