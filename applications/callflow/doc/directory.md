## Directory

### About Directory

Match DTMF keypresses to the directory's listing to find callees.

#### Schema

Validator for the directory callflow data object



Key | Description | Type | Default | Required | Support Level
--- | ----------- | ---- | ------- | -------- | -------------
`id` | Directory ID | `string()` |   | `false` |  
`skip_module` | When set to true this callflow action is skipped, advancing to the wildcard branch (if any) | `boolean()` |   | `false` |  



