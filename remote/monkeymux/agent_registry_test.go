package main

import "testing"

func TestAgentRegistryKeysAreDistinct(t *testing.T) {
	if len(agentTools) != len(agentRegistry) {
		t.Fatalf("agentTools lists %d tools, registry has %d", len(agentTools), len(agentRegistry))
	}
	commandNames, providerIDs, titles := map[string]string{}, map[string]string{}, map[string]string{}
	for _, tool := range agentTools {
		descriptor, ok := agentRegistry[tool]
		if !ok || len(descriptor.commandNames) == 0 {
			t.Fatalf("%s has no registry entry with command names", tool)
		}
		for _, name := range descriptor.commandNames {
			if owner, dup := commandNames[name]; dup {
				t.Errorf("command name %q claimed by %s and %s", name, owner, tool)
			}
			commandNames[name] = tool
		}
		for _, id := range descriptor.acpProviderIDs {
			if owner, dup := providerIDs[id]; dup {
				t.Errorf("provider %q claimed by %s and %s", id, owner, tool)
			}
			providerIDs[id] = tool
		}
		for _, title := range append(append([]string(nil), descriptor.titles...), descriptor.titlePrefixes...) {
			if owner, dup := titles[title]; dup {
				t.Errorf("title %q claimed by %s and %s", title, owner, tool)
			}
			titles[title] = tool
		}
	}
	for tool, descriptor := range agentRegistry {
		if (descriptor.hookIdentity != nil) && !descriptor.wrappedLaunch {
			t.Errorf("%s has an identity hook but is not launched through agent-launch", tool)
		}
	}
}
