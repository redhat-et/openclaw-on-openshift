@security @csb
Feature: OpenClaw CSB policy
  The repository defines the application and sandbox boundaries used by the
  documented OpenShell deployment.

  Rule: The OpenClaw CSB policy shall fully permit exec under sandbox enforcement.
    Scenario: Exec is fully permitted under sandbox enforcement
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then exec should be fully permitted under sandbox enforcement

  Rule: The OpenClaw CSB policy shall expose only explicitly configured skills.
    Scenario: Skill visibility defaults to no skills
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then skill visibility should be explicit

  Rule: If a runtime skill or plugin installation is requested, then the OpenClaw CSB policy shall reject the installation.
    Scenario: Runtime customization fails closed
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then runtime installs should fail closed

  Rule: The OpenShell CSB policy shall authorize only declared filesystem, identity, and network access.
    Scenario: Canonical policy declares exact boundaries
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the OpenShell policy should be canonical and least privilege

  Rule: When the Google Workspace provider is attached, Gmail shall be read-only while Calendar permits writes.
    Scenario: Google Workspace credentials and policy have mixed least-privilege access
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then Google Workspace should be brokered through gog with mixed access

  Rule: Native Google Workspace widgets shall remain isolated without enabling the MCP Apps bridge.
    Scenario: Google Workspace dashboard uses the native widget sandbox
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then native Google Workspace widgets should be available without MCP Apps

  Rule: When an owner requests a gateway restart, OpenClaw shall restart without recreating its sandbox.
    Scenario: Gateway lifecycle preserves sandbox state
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the helper should manage the OpenClaw gateway lifecycle

  Rule: The OpenShell README deployment shall apply version-controlled policy and persistent Podman storage.
    Scenario: Deployment instructions reproduce the security posture
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the README should describe the reproducible deployment

  Rule: When OpenClaw starts, the OpenClaw CSB configuration shall require a supplied gateway token.
    Scenario: Persistent state cannot supply a stale authentication fallback
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then configuration without a gateway token should fail closed

  Rule: If an unsafe origin or provider configuration is supplied, then the OpenClaw CSB configuration shall preserve the last valid configuration.
    Scenario: Invalid external configuration is rejected before replacement
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then invalid runtime inputs should preserve the existing configuration

  Rule: When valid runtime inputs are supplied, the OpenClaw CSB configuration shall atomically apply the managed policy without duplicating the gateway token.
    Scenario: Valid configuration replaces persistent state safely
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then valid runtime inputs should produce protected configuration

  Rule: When an OpenAI API key provider is selected, OpenClaw shall route model traffic through OpenShell inference without exposing the key to the sandbox.
    Scenario: OpenAI API key configures inference.local
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then an OpenAI API key should configure inference.local

  Rule: When an Anthropic API key provider is attached, OpenClaw shall enable the Anthropic model route without persisting the key.
    Scenario: Brokered Anthropic API key configures Claude
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then a brokered Anthropic API key should configure Claude

  Rule: When persistent state is configured, the OpenClaw CSB entrypoint shall direct OpenClaw to the managed configuration file.
    Scenario: Image defaults do not shadow persistent state configuration
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then the managed configuration path should use supported OpenClaw variables

  Rule: The OpenClaw CSB install policy shall return a block decision without waiting for request stream closure.
    Scenario: Installation denial is immediate
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then runtime install denial should be immediate

  Rule: The OpenClaw CSB build shall use immutable upstream inputs and committed dependency resolution.
    Scenario: Repeated builds resolve the declared source inputs
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then build inputs should be immutable

  Rule: The OpenClaw CSB policy shall enable cron for unattended skill execution.
    Scenario: Cron is enabled for scheduled tasks
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then cron should be enabled

  Rule: When production dependencies are selected, the OpenClaw CSB build shall fail if dependency selection fails.
    Scenario: Build cleanup cannot mask dependency selection errors
      Given the OpenClaw CSB repository
      When the CSB security artifacts are inspected
      Then production dependency selection should fail closed
