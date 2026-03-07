# Fazm — Your AI Computer Agent

The fastest AI computer agent. Controls your browser, writes code, handles documents, operates Google Apps, and learns your workflow — all from your voice.

**Free to start. Fully open source. Fully local.**

🌐 [fazm.ai](https://fazm.ai)

## Demos

### Twitter Automation
Fazm browses Twitter, engages with posts, and manages your social presence hands-free.

https://github.com/user-attachments/assets/8af42297-27f0-4b80-8eed-1d739c21208e

### Smart Connections
Automatically find and connect with the right people across platforms.

https://github.com/user-attachments/assets/09cbf88d-6a11-45a4-9182-6c61127a3672

### CRM Management
Keep your CRM up to date without lifting a finger — Fazm handles data entry and updates.

https://github.com/user-attachments/assets/16454649-7375-450b-aa61-11f227cb15a3

### Visual Tasks
Fazm understands images and visual context to complete complex workflows.

https://github.com/user-attachments/assets/7f1d9f69-3825-40fd-af91-12c27fef7845

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
