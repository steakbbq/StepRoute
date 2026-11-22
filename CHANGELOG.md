# Changelog

A version section is `## X.Y.Z [release]` (or `[beta]`, `[alpha]`). The release workflow sends that text and type to CurseForge.

## 0.1.2 [release]
- The Mapzeroth route is named after the step text: the last line of the step plus ` #N`, for example `Fly to Wetlands #37`.
- A step with no text uses the guide name, as before.
- The log shows the name used (`text=`, `src=`).

## 0.1.1 [release]
- The route name uses the guide name that RestedXP shows, not its internal key.
- The log has a `GUIDE` line per guide change.

## 0.1.0 [release]
- First version. A new RestedXP step with a map point sets a Mapzeroth route.
- Waits for combat to end. Read only: nothing on RestedXP or Mapzeroth is changed.
- `/stepr on|off|start on|off|now`.
