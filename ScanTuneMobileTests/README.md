# ScanTuneMobileTests

Tests unitaires pour la logique pure de ScanTune Mobile (modèles, parsers,
détecteurs). Ces fichiers ne sont **pas encore branchés** dans le projet
Xcode — il faut créer un Test Target manuellement.

## Comment activer ces tests dans Xcode

1. Ouvrir `ScanTuneMobile.xcodeproj`.
2. File → New → Target… → **iOS Unit Testing Bundle**.
3. Nom : `ScanTuneMobileTests`. Hôte : `ScanTuneMobile`. Langage : Swift.
4. Cocher *Include UI Tests* si voulu (sinon laisser décoché).
5. Une fois le target créé, ouvrir le navigateur de projet :
   - Supprimer le fichier d'exemple `ScanTuneMobileTests.swift` généré.
   - Glisser-déposer **tous les `.swift` de ce dossier** dans le groupe
     du test target (ne pas cocher *Copy items if needed*, cocher
     *ScanTuneMobileTests* comme target).
6. Build phase → vérifier que les fichiers source apparaissent dans
   *Compile Sources* du test target.
7. Lancer les tests : ⌘U.

## Périmètre testé

- **`QRPayloadTests`** : parsing JSON du payload QR (serial obligatoire, champs
  inconnus ignorés, chaîne non-JSON rejetée).
- **`AnomalyDetectorTests`** : règles stale sync, non-compliant + user actif,
  doublons série, indexation par device.
- **`InventoryFileMergeTests`** : merge append-only idempotent.
- **`PDFReportBuilderTests`** : génération PDF (existence du fichier,
  taille minimale, multi-pages).

## Pas testé ici

- Les services réseau (`GraphService`, `SharePointInventoryService`,
  `AuthService`) — nécessitent un mocking via protocoles pour rester
  unit-testables. À planifier dans un second temps.
- Les vues SwiftUI — couvrables via Snapshot Tests ou XCUITest, hors scope.
