#!/bin/zsh

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
presentation_source="$project_dir/Sources/OsXtermApp/AppPresentation.swift"
terminal_surface_source="$project_dir/Sources/OsXtermApp/AppKitTerminalSurface.swift"
settings_source="$project_dir/Sources/OsXtermApp/SettingsView.swift"

theme_specs=(
    'system|System'
    'midnight|Midnight'
    'solarizedDark|Solarized Dark'
    'solarizedLight|Solarized Light'
    'dracula|Dracula'
    'nord|Nord'
    'gruvboxDark|Gruvbox Dark'
    'gruvboxLight|Gruvbox Light'
    'catppuccinMocha|Catppuccin Mocha'
    'catppuccinLatte|Catppuccin Latte'
    'tokyoNight|Tokyo Night'
    'tokyoNightStorm|Tokyo Night Storm'
    'monokaiPro|Monokai Pro'
    'oneDark|One Dark'
    'githubDark|GitHub Dark'
    'githubLight|GitHub Light'
    'rosePine|Rosé Pine'
    'everforestDark|Everforest Dark'
    'ayuMirage|Ayu Mirage'
    'kanagawaWave|Kanagawa Wave'
)
font_cases=(d2Coding jetBrainsMono firaCode hack)

for source_file in "$presentation_source" "$terminal_surface_source" "$settings_source"; do
    if [[ ! -f "$source_file" ]]; then
        echo "Missing terminal catalog source: $source_file" >&2
        exit 1
    fi
done

theme_case_count="$(sed -n '/^enum TerminalTheme:/,/^}/p' "$presentation_source" | rg -c '^[[:space:]]*case [A-Za-z0-9]+ = "')"
if [[ "$theme_case_count" -ne ${#theme_specs[@]} ]]; then
    echo "Expected ${#theme_specs[@]} terminal themes, found $theme_case_count." >&2
    exit 1
fi

for theme_spec in "${theme_specs[@]}"; do
    identifier="${theme_spec%%|*}"
    name="${theme_spec#*|}"
    if ! rg -Fq "case $identifier = \"$name\"" "$presentation_source"; then
        echo "Missing terminal theme declaration: $name" >&2
        exit 1
    fi
    if ! rg -Fq "case .$identifier:" "$terminal_surface_source"; then
        echo "Missing terminal theme palette: $name" >&2
        exit 1
    fi
done

font_case_count="$(sed -n '/^enum TerminalFont:/,/^}/p' "$presentation_source" | rg -c '^[[:space:]]*case [A-Za-z0-9]+ = "')"
if [[ "$font_case_count" -ne ${#font_cases[@]} ]]; then
    echo "Expected ${#font_cases[@]} bundled terminal fonts, found $font_case_count." >&2
    exit 1
fi

for font_case in "${font_cases[@]}"; do
    if ! rg -Fq "case $font_case = " "$presentation_source"; then
        echo "Missing bundled terminal font declaration: $font_case" >&2
        exit 1
    fi
done

if ! rg -Fq 'ForEach(TerminalTheme.allCases)' "$settings_source"; then
    echo "Settings does not expose the complete terminal theme catalog." >&2
    exit 1
fi
if ! rg -Fq 'ForEach(TerminalFont.allCases)' "$settings_source"; then
    echo "Settings does not expose the complete bundled font catalog." >&2
    exit 1
fi
if ! rg -Fq 'TerminalThemeVisualStyle.resolve' "$terminal_surface_source"; then
    echo "Terminal surface does not apply the selected theme." >&2
    exit 1
fi
if ! rg -Fq 'BundledTerminalFontRegistry.font' "$terminal_surface_source"; then
    echo "Terminal surface does not apply the selected bundled font." >&2
    exit 1
fi
if rg -q 'NSFontPanel|NSFontManager|FontPicker' "$project_dir/Sources/OsXtermApp"; then
    echo "Terminal font selection must not expose the macOS system font collection." >&2
    exit 1
fi

echo "Verified ${#theme_specs[@]} terminal themes and ${#font_cases[@]} bundled terminal fonts."
