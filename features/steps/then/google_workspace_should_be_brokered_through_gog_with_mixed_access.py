from behave import then


@then("Google Workspace should be brokered through gog with mixed access")
def step_impl(context):
    context.policy.assert_google_workspace_is_brokered_through_gog()
