from behave import then


@then("an OpenAI API key should configure inference.local")
def step_impl(context):
    context.repository.assert_openai_api_key_configures_inference_local()
