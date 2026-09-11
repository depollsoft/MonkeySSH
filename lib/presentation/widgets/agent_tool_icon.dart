import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../domain/models/agent_launch_preset.dart';
import 'agent_tool_marks.dart';

/// Resolves the shared identity tint for terminal and native agent windows.
///
/// Activity belongs in status/progress UI; only window selection changes the
/// tool mark and native identity badge.
Color agentWindowIdentityColor(ColorScheme scheme, {required bool isActive}) =>
    isActive ? scheme.primary : scheme.onSurfaceVariant;

/// Renders a branded icon for a supported coding-agent CLI.
class AgentToolIcon extends StatelessWidget {
  /// Creates a new [AgentToolIcon].
  const AgentToolIcon({
    super.key,
    this.tool,
    this.toolName,
    this.size = 20,
    this.color,
    this.fallbackIcon = Icons.smart_toy_outlined,
  });

  /// The resolved tool to render, if already known.
  final AgentLaunchTool? tool;

  /// A human-readable tool name to resolve when [tool] is unavailable.
  final String? toolName;

  /// The square icon size.
  final double size;

  /// Optional explicit icon tint.
  final Color? color;

  /// The fallback Material icon to use for unknown tools.
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final resolvedTool = tool ?? _agentToolForLabel(toolName);
    final effectiveColor =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurfaceVariant;

    final svg = resolvedTool == null ? null : _svgByTool[resolvedTool];
    if (svg == null) {
      return Icon(fallbackIcon, size: size, color: effectiveColor);
    }

    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: SvgPicture.string(
          svg,
          width: size,
          height: size,
          colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
        ),
      ),
    );
  }
}

AgentLaunchTool? _agentToolForLabel(String? toolName) {
  final normalized = toolName?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }

  for (final tool in AgentLaunchTool.values) {
    if (tool.label == normalized) {
      return tool;
    }
  }
  return null;
}

String _buildSvg(String viewBox, List<_SvgPathSpec> paths) {
  final buffer = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="$viewBox">',
  );
  for (final path in paths) {
    buffer.write('<path d="${path.data}" fill="currentColor"');
    if (path.fillRule != null) {
      buffer.write(' fill-rule="${path.fillRule}"');
    }
    if (path.clipRule != null) {
      buffer.write(' clip-rule="${path.clipRule}"');
    }
    buffer.write('/>');
  }
  buffer.write('</svg>');
  return buffer.toString();
}

final Map<AgentLaunchTool, String> _svgByTool = <AgentLaunchTool, String>{
  // Grok Build's monochrome mark from xAI's supplied SVG.
  AgentLaunchTool.grokBuild: _buildSvg('0.36 0.5 33.33 32', const [
    _SvgPathSpec(
      'M13.2371 21.0407L24.3186 12.8506C24.8619 12.4491 25.6384 12.6057 25.8973 13.2294C27.2597 16.5185 26.651 20.4712 23.9403 23.1851C21.2297 25.8989 17.4581 26.4941 14.0108 25.1386L10.2449 26.8843C15.6463 30.5806 22.2053 29.6665 26.304 25.5601C29.5551 22.3051 30.562 17.8683 29.6205 13.8673L29.629 13.8758C28.2637 7.99809 29.9647 5.64871 33.449 0.844576C33.5314 0.730667 33.6139 0.616757 33.6964 0.5L29.1113 5.09055V5.07631L13.2343 21.0436',
    ),
    _SvgPathSpec(
      'M10.9503 23.0313C7.07343 19.3235 7.74185 13.5853 11.0498 10.2763C13.4959 7.82722 17.5036 6.82767 21.0021 8.2971L24.7595 6.55998C24.0826 6.07017 23.215 5.54334 22.2195 5.17313C17.7198 3.31926 12.3326 4.24192 8.67479 7.90126C5.15635 11.4239 4.0499 16.8403 5.94992 21.4622C7.36924 24.9165 5.04257 27.3598 2.69884 29.826C1.86829 30.7002 1.0349 31.5745 0.36364 32.5L10.9474 23.0341',
    ),
  ]),
  // Pi's own blocky monogram, taken from the lobehub icon set. Preferred over
  // a plain Greek pi glyph so it reads as the brand rather than a maths symbol.
  AgentLaunchTool.pi: _buildSvg('0 0 24 24', const [
    _SvgPathSpec(
      'M1 1h16.5v11H12v5.5H6.5V23H1V1zm5.5 5.5V12H12V6.5H6.5z',
      fillRule: 'evenodd',
      clipRule: 'evenodd',
    ),
    _SvgPathSpec('M17.5 12H23v11h-5.5V12z'),
  ]),
  // Hermes ships the Nous Research portrait as its mark; it is reproduced
  // verbatim from the lobehub icon set rather than redrawn.
  AgentLaunchTool.hermes: hermesAgentMarkSvg,
  // OpenClaw's own monochrome menu-bar mark: a silhouette with knocked-out
  // eyes, so the icon still reads as its mascot when tinted to one colour.
  AgentLaunchTool.openclaw:
      '<svg viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg"> '
      '<mask id="critter" maskUnits="userSpaceOnUse" x="0" y="0" width="18" '
      'height="18"> <g fill="#fff"> '
      '<g fill="none" stroke="#fff" stroke-width="2.07" '
      'stroke-linecap="round"> '
      '<path d="M6.926 4.563 Q6.149 1.35 3.816 1.62"/> '
      '<path d="M11.074 4.563 Q11.851 1.35 14.184 1.62"/> </g> '
      '<rect x="5.4" y="12.96" width="2.52" height="3.24" rx="1.26"/> '
      '<rect x="10.08" y="12.96" width="2.52" height="3.24" rx="1.26"/> '
      '<circle cx="2.7" cy="9.59" r="1.8"/> '
      '<circle cx="15.3" cy="9.59" r="1.8"/> '
      '<ellipse cx="9" cy="8.64" rx="6.48" ry="5.94"/> </g> '
      '<g fill="#000"> '
      '<ellipse cx="6.149" cy="7.69" rx="1.426" ry="1.544"/> '
      '<ellipse cx="11.851" cy="7.69" rx="1.426" ry="1.544"/> </g> '
      '<g fill="#fff"> '
      '<circle cx="5.522" cy="7.134" r="0.741"/> '
      '<circle cx="11.224" cy="7.134" r="0.741"/> </g> </mask> '
      '<rect width="18" height="18" fill="#000" mask="url(#critter)"/> '
      '</svg>',
  AgentLaunchTool.claudeCode: _buildSvg('0 0 24 24', const [
    _SvgPathSpec(
      '''m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z''',
    ),
  ]),
  AgentLaunchTool.copilotCli: _buildSvg('0 0 24 24', const [
    _SvgPathSpec(
      '''M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z''',
    ),
  ]),
  AgentLaunchTool.codex: _buildSvg('0 0 24 24', const [
    _SvgPathSpec(
      '''M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z''',
      fillRule: 'evenodd',
      clipRule: 'evenodd',
    ),
  ]),
  AgentLaunchTool.openCode: _buildSvg('0 0 512 512', const [
    _SvgPathSpec('M320 224V352H192V224H320Z'),
    _SvgPathSpec(
      'M384 416H128V96H384V416ZM320 160H192V352H320V160Z',
      fillRule: 'evenodd',
      clipRule: 'evenodd',
    ),
  ]),
  AgentLaunchTool.antigravity: _buildSvg('13 14.5 85 85', const [
    _SvgPathSpec(
      'M89.6992 93.695C94.3659 97.195 101.366 94.8617 94.9492 88.445C75.6992 69.7783 79.7825 18.445 55.8659 18.445C31.9492 18.445 36.0325 69.7783 16.7825 88.445C9.78251 95.445 17.3658 97.195 22.0325 93.695C40.1159 81.445 38.9492 59.8617 55.8659 59.8617C72.7825 59.8617 71.6159 81.445 89.6992 93.695Z',
    ),
  ]),
  AgentLaunchTool.cursorAgent: _buildSvg('0 0 24 24', const [
    _SvgPathSpec(
      '''M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23''',
    ),
  ]),
};

class _SvgPathSpec {
  const _SvgPathSpec(this.data, {this.fillRule, this.clipRule});

  final String data;
  final String? fillRule;
  final String? clipRule;
}
