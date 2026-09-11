import 'package:flutter/material.dart';

import 'terminal_text_style.dart';

/// Display name for a terminal font.
String fontFamilyLabel(String family) => switch (family) {
  'monospace' => 'System Monospace',
  'VT323' => 'VT323 (Retro)',
  _ => family,
};

/// Shows a font picker dialog and returns the selected font family.
Future<String?> showFontPickerDialog({
  required BuildContext context,
  String? currentFontFamily,
  String title = 'Terminal Font',
  double previewFontSize = 14,
}) async {
  const options = [
    'monospace',
    'JetBrains Mono',
    'Fira Code',
    'Source Code Pro',
    'Ubuntu Mono',
    'Roboto Mono',
    'IBM Plex Mono',
    'Inconsolata',
    'Anonymous Pro',
    'Cousine',
    'PT Mono',
    'Space Mono',
    'VT323',
    'Share Tech Mono',
    'Overpass Mono',
    'Oxygen Mono',
  ];
  const previewText = 'AaBbCc 0123 {}[]';
  TextStyle fontStyle(String family) =>
      resolveMonospaceTextStyle(family, fontSize: previewFontSize);

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            // Current selection preview
            if (currentFontFamily != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withAlpha(50),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.primary.withAlpha(100),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Currently Selected',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          Text(
                            fontFamilyLabel(currentFontFamily),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            previewText,
                            style: fontStyle(currentFontFamily),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            // Font list
            Expanded(
              child: ListView.builder(
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final family = options[index];
                  final isSelected = family == currentFontFamily;
                  return ListTile(
                    title: Text(fontFamilyLabel(family)),
                    subtitle: Text(previewText, style: fontStyle(family)),
                    selected: isSelected,
                    trailing: isSelected ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(context, family),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
