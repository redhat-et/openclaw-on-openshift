from behave import then


@then("the helper should manage the OpenClaw gateway lifecycle")
def step_impl(context):
    context.policy.assert_helper_manages_gateway_lifecycle()
