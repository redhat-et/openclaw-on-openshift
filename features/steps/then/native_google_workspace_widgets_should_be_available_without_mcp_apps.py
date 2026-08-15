from behave import then


@then("native Google Workspace widgets should be available without MCP Apps")
def step_impl(context):
    context.policy.assert_native_google_workspace_widgets_are_available()
