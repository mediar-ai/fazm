# Fazm — Your AI Computer Agent

The fastest AI computer agent. Controls your browser, writes code, handles documents, operates Google Apps, and learns your workflow — all from your voice.

**Free to start. Fully open source. Fully local.**

🌐 [fazm.ai](https://fazm.ai/gh)

## Demos

### How Fazm Works

https://github.com/user-attachments/assets/42478070-9c32-48cc-b18a-61c646c6b6bd

### Smart Connections
Automatically find and connect with the right people across platforms.

https://github.com/user-attachments/assets/442d69a6-fd07-4f39-9335-cca7e2fdb884

### CRM Management
Keep your CRM up to date without lifting a finger — Fazm handles data entry and updates.

https://github.com/user-attachments/assets/9ab447d3-7a47-4c9b-8880-aa06477ba5b5

### Visual Tasks
Fazm understands images and visual context to complete complex workflows.

https://github.com/user-attachments/assets/66bdbf38-c6fe-4437-987d-78429a2d9e2a

## Structure

```
Desktop/        Swift/SwiftUI macOS app (SPM package)
acp-bridge/     ACP bridge for Claude integration (TypeScript)
dmg-assets/     DMG installer resources
```

## Development

Requires macOS 14.0+, Xcode, and code signing with an Apple Developer ID.

```bash
# Run (builds Swift app and launches)
./run.sh

# Run with clean slate (resets onboarding, permissions, UserDefaults)
./reset-and-run.sh
```

## License

MIT
