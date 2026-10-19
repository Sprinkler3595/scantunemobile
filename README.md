# ScanTune Mobile (iOS)

Application iOS de verification d'inventaire IT par scan QR, connectee a Microsoft Intune.

ScanTune Mobile permet aux techniciens IT de scanner les etiquettes QR des appareils sur le terrain, verifier leur presence physique et documenter l'etat de chaque appareil lors d'audits d'inventaire annuels, **sans jamais modifier les donnees Intune** (lecture seule cote Intune ; les verifications sont enregistrees dans un fichier d'inventaire centralise sur SharePoint).

## Fonctionnalites

### Scanner QR
- Scan en temps reel via la camera (QR, Code128, Code39, EAN13, EAN8, DataMatrix)
- Recherche automatique de l'appareil dans Intune par numero de serie, ID ou nom
- Historique des scans avec statut (trouve / non trouve)
- Retour haptique et sonore a chaque scan
- Affichage rapide des informations de l'appareil

### Inventaire annuel
- Creation de sessions d'inventaire avec nom et localisation
- Scan integre pour verification en lot des appareils
- Marquage de chaque appareil :
  - **Trouve** : l'appareil est present et en bon etat
  - **Endommage** : l'appareil presente des dommages
  - **Etiquette manquante** : le QR code est absent ou illisible
- Ajout de notes et localisation par appareil
- Suivi de progression (barre circulaire X/Total)
- Visualisation des appareils non encore verifies
- Recherche et filtres dans les appareils verifies
- Historique des sessions precedentes

### Fiche appareil
- Informations completes : identite, numero de serie, modele, OS
- Utilisateur assigne : nom, email, poste, departement, bureau
- Etat de conformite et d'inscription
- Stockage utilise (barre de progression)
- Dates d'inscription et derniere synchronisation
- Indicateur de statut (Healthy, Warning, Stale, Non-Compliant)

### Export
- Generation de rapports CSV des sessions d'inventaire
- Partage via ShareSheet iOS (Mail, iCloud Drive, Notes, etc.)

## Stack technique

| Composant | Technologie |
|-----------|-------------|
| Framework UI | SwiftUI |
| Langage | Swift 5+ |
| Architecture | MVVM (ObservableObject) |
| Authentification | MSAL (Microsoft Authentication Library for iOS) |
| API | Microsoft Graph API v1.0 (REST) |
| Scanner | AVFoundation (AVCaptureSession) |
| Stockage local | FileManager (JSON) + Keychain |
| Feedback | AudioToolbox + UIKit Haptics |

## Structure du projet

```
ScanTuneInventory-IOS/
└── ScanTuneMobile/
    ├── ScanTuneMobileApp.swift          # Point d'entree de l'application
    ├── Info.plist                        # Configuration (camera, URL schemes)
    ├── Assets.xcassets/                  # Icones et couleurs
    ├── Models/
    │   ├── Device.swift                  # Modele appareil Intune
    │   ├── User.swift                    # Modele utilisateur Entra ID
    │   ├── QRPayload.swift                # Parser JSON QR code ScanTune
    │   ├── InventoryRecord.swift          # Record d'inventaire (append-only, schema v2)
    │   └── InventorySettings.swift        # Reglages SharePoint + perimetre d'appareils
    ├── Views/
    │   ├── ContentView.swift             # Navigation principale (Login / Tabs)
    │   ├── ScannerView.swift             # Onglet Scanner QR
    │   ├── DeviceDetailView.swift        # Detail d'un appareil (modale)
    │   ├── InventoryView.swift           # Accueil inventaire : liste des entreprises
    │   ├── InventoryCompanyView.swift    # Devices d'une entreprise + scanner
    │   ├── InventoryScanFormView.swift   # Formulaire validation d'un scan
    │   └── InventorySettingsView.swift   # Reglages SharePoint in-app
    ├── ViewModels/
    │   ├── ScannerViewModel.swift        # Logique du scanner
    │   ├── InventoryViewModel.swift      # Orchestration inventaire (Graph + SharePoint + queue)
    │   └── DeviceViewModel.swift         # Chargement detail appareil
    ├── Services/
    │   ├── AuthService.swift             # Authentification MSAL / OAuth2
    │   ├── GraphService.swift            # Appels Microsoft Graph API
    │   ├── OneDriveService.swift         # Upload OneDrive (archives)
    │   ├── SharePointInventoryService.swift # Lecture/ecriture fichier JSON SharePoint centralise
    │   └── InventoryQueueStore.swift     # File d'attente locale + sync auto (NWPathMonitor)
    └── Helpers/
        ├── QRScannerHelper.swift         # Controleur camera AVFoundation
        └── XLSXWriter.swift              # Generation XLSX (archives)
```

## Prerequisites

- macOS avec Xcode 15+
- iOS 16+ (appareil physique recommande pour le scanner)
- Une App Registration Azure AD avec les scopes suivants :
  - `DeviceManagementManagedDevices.Read.All`
  - `User.Read.All`
  - `Files.ReadWrite`
  - `Sites.ReadWrite.All` (**consentement admin requis** pour l'inventaire SharePoint centralise)
- Le redirect URI `msauth.com.scantune.mobile://auth` configure dans Azure AD

**Note sur l'inventaire v2 centralise :** apres l'ajout du scope `Sites.ReadWrite.All`,
chaque technicien devra effectuer UNE reconnexion interactive (le refresh silent renverra
`interactionRequired`). Ensuite toutes les connexions redeviennent silencieuses.

## Installation

```bash
git clone https://github.com/sprinkler3595/ScanTuneInventory-IOS.git
cd ScanTuneInventory-IOS
open ScanTuneMobile.xcodeproj
```

Dans Xcode :
1. Selectionner votre equipe de signature (Signing & Capabilities)
2. Installer les dependances MSAL (Swift Package Manager)
3. Builder et lancer sur un appareil physique (le scanner necessite la camera)

## Configuration

### Tenant de connexion

Le tenant Microsoft Entra ID et l'App Registration sont configurables directement dans l'app :
sur l'ecran de connexion, toucher la ligne **Tenant : ...** en bas de l'ecran, puis renseigner :

- **Tenant** : ID du tenant (GUID) ou domaine verifie (ex: `contoso.onmicrosoft.com`)
- **Client ID** : Application ID de l'App Registration dans ce tenant

La configuration est conservee sur l'appareil (y compris apres deconnexion). Changer de tenant
purge les comptes MSAL en cache : la connexion suivante est interactive. Pour changer de tenant
une fois connecte, se deconnecter d'abord.

L'App Registration du tenant cible doit declarer le redirect URI `msauth.com.scantune.mobile://auth`
et disposer des permissions Graph listees ci-dessus (avec consentement admin).

Les valeurs par defaut (tenant d'origine) sont definies dans `TenantConfiguration.defaults`
(`ScanTuneMobile/Models/TenantConfiguration.swift`).

## Securite

- **Lecture seule cote Intune** : aucune ecriture vers Intune (uniquement des appels GET sur les appareils et utilisateurs)
- Les verifications d'inventaire sont ecrites dans un fichier JSON centralise sur **SharePoint** (scope `Sites.ReadWrite.All`), jamais dans Intune
- Authentification OAuth2 via Microsoft Entra ID
- Tokens stockes dans le Keychain iOS
- Donnees d'inventaire mises en cache localement (snapshot + file d'attente, fichiers proteges) puis synchronisees vers SharePoint
- Transport securise (ATS active, pas de connexions HTTP)

## Stockage local

L'app conserve localement, dans le repertoire Documents, des fichiers de cache/tampon :
- `Documents/inventory_queue.json` — file d'attente des verifications en attente d'upload SharePoint
- `Documents/device_snapshot.json` — snapshot du parc (devices + users) pour le mode hors-ligne

Les verifications sont synchronisees vers le fichier d'inventaire centralise SharePoint des que le reseau est disponible. Aucune donnee n'est jamais ecrite dans Intune.

## Lien avec ScanTune Desktop

Cette application est le **compagnon mobile** de [ScanTune Desktop (WPF)](https://github.com/sprinkler3595/ScanTune-WPF). Le workflow typique :

1. **Desktop** : generer et imprimer les etiquettes QR sur imprimante Zebra
2. **Mobile** : scanner les QR codes sur le terrain pour verifier l'inventaire
3. **Desktop** : exporter les rapports d'inventaire (PDF, Excel, CSV)

## Localisation

L'interface est entierement en **francais**.
