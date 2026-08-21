# JPT AI for KOReader

Your reading companion for KOReader: select any word or passage and ask AI for its meaning, an explanation, a summary, a translation, or a discussion in the context of the book.

<p align="center">
  <img src="plugin_01.jpg" alt="JPT AI question composer in KOReader" height="450" />
  <img src="plugin_02.jpg" alt="JPT AI answer displayed in KOReader" height="450" />
</p>

## Features

- Ask free-form questions about the current page, chapter, book, or selected text.
- Get the contextual meaning of a selected word or expression with one tap.
- Explain, summarize, and translate selected passages with one tap.
- Pick the primary and secondary reading contexts directly in the question dialog.
- Remember separate secondary-context choices for questions with and without selected text.
- Adjust response font size, translation language, and response length from the plugin options. Choose **Short**, **Medium**, **Long**, or **Very long**; the setting is remembered for future questions.
- Send requests to an AI chat-completions endpoint that you configure yourself.

## Requirements

- A device running KOReader.
- Network access from KOReader.
- An API key and a compatible AI chat-completions endpoint.

## Installation

1. Copy this directory to KOReader's `plugins` directory as `jpt_ai.koplugin`.
2. Create the private configuration file:

   ```sh
   cp jpt_ai_config.example.lua jpt_ai_config.lua
   ```

3. Edit `jpt_ai_config.lua` with your endpoint, API key, model, and preferred request settings.
4. Restart KOReader.

`jpt_ai_config.lua` is deliberately excluded from Git, so your endpoint and API key remain local to your device.

## Configuration

`jpt_ai_config.lua` has this shape:

```lua
return {
    base_url = "https://your-api-host.example/v1/chat/completions",
    api_key = "your-api-key",
    model = "your-model-name",
    temperature = 0.2,
    max_output_tokens = 12000,
    request_timeout = 180,
    reasoning_effort = "low",
}
```

Use the URL required by your AI provider. Never commit `jpt_ai_config.lua` or share its API key.

## Using the plugin

- Open **JPT AI** from KOReader's tools menu or bind its `Open JPT AI` action to a gesture.
- Select text in a book and choose **JPT AI** from the selection menu.
- Use **Meaning**, **Explain**, **Summarize**, or **Translate** for a quick response, or write a custom question.
- Without selected text, use **MAIN CONTEXT** to choose primary pages, the current chapter, or the complete book. Primary **Pages (n)** uses an odd total: 1, 3, 5, and so on.
- With selected text, the selection is shown as the fixed **MAIN CONTEXT**.
- With selected text, the single **SECONDARY CONTEXT** row contains **None**, **Page**, **Pages ±N**, **Chapter**, and **Book**.
- Without selected text, the same compact row contains **None**, **Pages ±N**, **Chapter**, and **Book**. **Page** is omitted because the Main context already contains the current page.
- Tapping **Pages ±N** selects it immediately. Closing the number selector without changing N keeps **Pages ±N** selected.

### Quick-action labels

The detailed instructions sent to the configured model remain hidden. The answer dialog identifies only the chosen action and its target:

| Button | Selected text | Pages | Chapter | Book |
| --- | --- | --- | --- | --- |
| **Meaning** | `Meaning: <selected text>` | `Meaning: current page (<page number>)` | `Meaning: current chapter (<chapter>)` | `Meaning: current book - <book name>` |
| **Explain** | `Explain: <selected text>` | `Explain: current page (<page number>)` | `Explain: current chapter (<chapter>)` | `Explain: current book - <book name>` |
| **Summarize** | `Summarize: <selected text>` | `Summarize: current page (<page number>)` | `Summarize: current chapter (<chapter>)` | `Summarize: current book - <book name>` |
| **Translate** | `Translate: <selected text>` | `Translate: current page (<page number>)` | `Translate: current chapter (<chapter>)` | `Translate: current book - <book name>` |

For **Translate**, the model uses the language selected under **Options → Translation language**. The selected **Response length** controls the expected amount of detail and the maximum output-token allowance for every action; the quick actions do not impose their own response length.

### How Main and Secondary context are used

- **Main context** is the content the model must act on. When text is selected, the selection becomes the Main context. Otherwise, the chosen primary pages, chapter, or complete book become the Main context.
- With selected text, **MAIN CONTEXT** shows **Selected text** as a fixed status instead of showing irrelevant page, chapter, and book controls.
- **Secondary context** is optional supporting book text. It helps the model interpret the Main context, but it is not itself the content to explain, summarize, or translate.
- The plugin remembers separate Secondary-context choices for questions with and without selected text. **Page** is available only with a selection; without one, the Main context already contains the current page.
- **Meaning** relies on the Secondary context to identify how a selected word or expression is used in the surrounding text. With Secondary context disabled, the model may have only the selected word or expression and therefore less evidence for a context-specific meaning.
- Every request tells the model to base its answer strictly on the supplied book context, act on the Main context, and use the Secondary context only as supporting material.

| Secondary context | Exact content sent |
| --- | --- |
| **None** | No secondary text |
| **Page** | The complete current page; available only when text is selected |
| **Pages ±N** | The current page plus exactly N pages before and N pages after it, limited by the start and end of the book |
| **Chapter** | The complete current chapter |
| **Book** | The complete current book |

No additional book text is added automatically beyond the selected Secondary-context scope. A Secondary context may overlap the Main context when the user explicitly chooses an overlapping scope.

The answer dialog shows the quick-action label directly, such as `Meaning: current book - Book name`, without a preceding `Question:` heading.

## Privacy

The selected text and requested context are sent only to the endpoint configured in your private `jpt_ai_config.lua`. The plugin does not include an endpoint or API key in this repository.

## Compatibility

This plugin was tested on a **Kobo Clara BW (P365)** running KOReader. It is intended to work on any device that runs KOReader, although other devices and KOReader versions have not yet been tested.

## Repository contents

- `main.lua` — plugin implementation.
- `_meta.lua` — KOReader plugin metadata.
- `jpt_ai_config.example.lua` — safe private-configuration template.
