from behave import then


@then("a brokered Anthropic API key should configure Claude")
def step_impl(context):
    context.repository.assert_brokered_anthropic_api_key_configures_claude()
