# 🚀 ZapStore APK Publisher

A retro-styled Dart web application for publishing APK files to ZapStore using Nostr and the decentralized web!

## 🎯 Features

- **NIP-07 Integration**: Uses browser extensions like Alby or nos2x for Nostr signing
- **APK Publishing**: Upload APKs and publish them to the decentralized ZapStore
- **Retro UI**: Classic 1990s web design with Times New Roman and nostalgic styling
- **Blossom CDN**: Uploads files to `https://cdn.zapstore.dev`
- **Nostr Events**: Publishes to `relay.zapstore.dev`

## 🛠️ Prerequisites

1. **Dart SDK** - Install from https://dart.dev/get-dart
2. **zapstore CLI** - Must be installed and available in PATH
3. **nak CLI** - Must be installed and available in PATH
4. **NIP-07 Browser Extension** - Alby, nos2x, or similar

## 🚀 Quick Start

1. **Start the server:**
   ```bash
   ./run.sh
   ```

2. **Open your browser:**
   Navigate to `http://localhost:8080`

3. **Connect Nostr Extension:**
   Click "Connect Nostr Extension" and authorize

4. **Upload & Publish:**
   - Select your APK file
   - Optionally add repository URL
   - Click "PUBLISH TO ZAPSTORE"
   - Review the generated Nostr events with clear descriptions:
     * Application Description (Kind 32267)
     * Release Event (Kind 30063) 
     * Asset Event/File Metadata (Kind 1063)
   - Sign the events when prompted

## 🔧 How It Works

1. **Upload**: APK is uploaded and saved as `/tmp/{SHA-256}.apk`
2. **Process**: Creates YAML config and runs `zapstore publish -c file.yaml`
3. **Sign**: Frontend signs Nostr events using NIP-07 extension
4. **Publish**: Backend uploads to Blossom and publishes events via `nak`
5. **Cleanup**: Temporary files are removed

## 📁 Project Structure

```
browser-signer/
├── bin/
│   └── server.dart         # Main Dart HTTP server
├── web/
│   ├── index.html          # Retro frontend UI
│   └── app.js              # NIP-07 integration
├── pubspec.yaml            # Dart dependencies
├── run.sh                  # Launch script
└── README.md               # This file
```

## 🎨 Retro Styling

The frontend features authentic 1990s web design:
- Times New Roman typography
- Classic gray/silver color scheme (#c0c0c0)
- 3D inset/outset borders
- Marquee scrolling text
- Blinking animations
- Old-school button styling

## 🔐 Security

- Uses NIP-07 for secure Nostr key management
- APK files are temporarily stored with SHA-256 naming
- All temporary files are cleaned up after processing
- CORS headers properly configured

## 🐛 Troubleshooting

**"No NIP-07 extension found"**
- Install Alby, nos2x, or another NIP-07 compatible extension
- Refresh the page after installation

**"zapstore command failed"**
- Ensure zapstore CLI is installed and in PATH
- Check APK file is valid

**"Failed to publish to relay"**
- Ensure nak CLI is installed and in PATH
- Check internet connection to relay.zapstore.dev

---

**Built with ❤️ for the decentralized future!** ⚡🌸