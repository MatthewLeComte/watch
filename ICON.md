# App icon

Eden pixel1 wordmark. Label **Watch** (first letter capital, never all caps).

```bash
python3 "$HOME/Developer/GitHub/Work/Tooling/generate-wordmark-styles.py" \
  --style pixel1 --label Watch --all-sizes \
  --out-dir "$HOME/Developer/GitHub/Work/Tooling/icon-source/locked"
```

Slots live in `App/Assets.xcassets/AppIcon.appiconset`. Pure black is stamped to `(0, 0, 1)` so actool does not gray-encode the icon.
