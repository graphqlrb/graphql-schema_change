# Schema change catalog

Use these IDs in `policy.overrides` and `policy.allow`.
Conditional changes can receive a different classification or impact based on how a changed schema element is used.

| ID | Default classification | Impact | Conditional | Reason |
| --- | --- | --- | --- | --- |
| `APPLIED_DIRECTIVE_ADDED` | `safe` |  | Yes | A directive application was added and may affect runtime behavior. |
| `APPLIED_DIRECTIVE_ARGUMENT_CHANGED` | `safe` |  | Yes | An applied directive's arguments changed and may affect runtime behavior. |
| `APPLIED_DIRECTIVE_REMOVED` | `safe` |  | Yes | A directive application was removed and may affect runtime behavior. |
| `ARGUMENT_ADDED` | `safe` |  | Yes | Adding an optional argument preserves existing requests. |
| `ARGUMENT_DEFAULT_VALUE_CHANGED` | `dangerous` | `behavior` | Yes | Requests omitting this argument may behave differently. |
| `ARGUMENT_REMOVED` | `breaking` | `request` | No | Operations supplying this argument can become invalid. |
| `ARGUMENT_TYPE_CHANGED` | `breaking` | `request` | Yes | Values supplied for this argument may no longer be accepted. |
| `DEPRECATION_ADDED` | `safe` |  | No | This element is deprecated. Migrate its existing uses before it is removed. |
| `DEPRECATION_REASON_CHANGED` | `safe` |  | No | The deprecation reason changed. |
| `DEPRECATION_REMOVED` | `safe` |  | No | This element is no longer deprecated. |
| `DESCRIPTION_CHANGED` | `safe` |  | No | Description changes preserve existing requests and responses. |
| `DIRECTIVE_ADDED` | `safe` |  | No | Adding a directive preserves existing requests. |
| `DIRECTIVE_ARGUMENT_ADDED` | `safe` |  | Yes | Adding an optional directive argument preserves existing requests. |
| `DIRECTIVE_ARGUMENT_DEFAULT_VALUE_CHANGED` | `dangerous` | `behavior` | Yes | Operations omitting this directive argument may behave differently. |
| `DIRECTIVE_ARGUMENT_REMOVED` | `breaking` | `request` | Yes | Operations supplying this directive argument can become invalid. |
| `DIRECTIVE_ARGUMENT_TYPE_CHANGED` | `breaking` | `request` | Yes | Values supplied for this directive argument may no longer be accepted. |
| `DIRECTIVE_LOCATION_ADDED` | `safe` |  | No | The directive is available in an additional location. |
| `DIRECTIVE_LOCATION_REMOVED` | `breaking` | `request` | Yes | This directive can no longer be used at this location. |
| `DIRECTIVE_REMOVED` | `breaking` | `request` | Yes | Operations using this directive can become invalid. |
| `DIRECTIVE_REPEATABLE_ADDED` | `safe` |  | No | The directive can now be used more than once in a location. |
| `DIRECTIVE_REPEATABLE_REMOVED` | `breaking` | `request` | Yes | Operations repeating this directive in a location can become invalid. |
| `ENUM_VALUE_ADDED` | `safe` |  | Yes | Clients handling every possible response value may need to handle the new enum value. |
| `ENUM_VALUE_REMOVED` | `breaking` | `request` | Yes | This enum value can no longer be submitted or returned. |
| `FIELD_ADDED` | `safe` |  | No | Adding a field preserves existing selections. |
| `FIELD_REMOVED` | `breaking` | `request` | No | Operations selecting this field can become invalid. |
| `FIELD_TYPE_CHANGED` | `breaking` | `request`, `response` | Yes | The return type changed, which can affect selections and the shape of values. |
| `IMPLEMENTED_INTERFACE_ADDED` | `dangerous` | `response` | No | The interface can now return values of this type, affecting clients that branch on the concrete type. |
| `IMPLEMENTED_INTERFACE_REMOVED` | `breaking` | `request`, `response` | No | An interface no longer accepts this concrete type, which can invalidate fragment spreads and change responses. |
| `INPUT_FIELD_ADDED` | `safe` |  | Yes | Adding an optional input field preserves existing requests. |
| `INPUT_FIELD_DEFAULT_VALUE_CHANGED` | `dangerous` | `behavior` | Yes | Requests omitting this input field may behave differently. |
| `INPUT_FIELD_REMOVED` | `breaking` | `request` | No | Requests supplying this input field can become invalid. |
| `INPUT_FIELD_TYPE_CHANGED` | `breaking` | `request` | Yes | Values supplied for this input field may no longer be accepted. |
| `INPUT_OBJECT_ONE_OF_ADDED` | `breaking` | `request` | No | Exactly one non-null input field must now be supplied. |
| `INPUT_OBJECT_ONE_OF_REMOVED` | `safe` |  | No | Requests can now supply multiple input fields or omit all of them. |
| `ROOT_OPERATION_TYPE_ADDED` | `safe` |  | No | A new operation kind is available. |
| `ROOT_OPERATION_TYPE_CHANGED` | `breaking` | `request`, `response` | No | The root type changed, which can affect selections, type conditions and __typename. |
| `ROOT_OPERATION_TYPE_REMOVED` | `breaking` | `request` | No | Operations of this kind can no longer run. |
| `SCALAR_SPECIFIED_BY_CHANGED` | `dangerous` | `response` | Yes | The specification for the scalar's value format changed. |
| `TYPE_ADDED` | `safe` |  | No | Adding a type preserves existing uses. |
| `TYPE_KIND_CHANGED` | `breaking` | `request`, `response` | No | A change in the kind of type can affect selections and the shape of values. |
| `TYPE_REMOVED` | `breaking` | `request` | No | Operations that reference this type can become invalid. |
| `UNION_MEMBER_ADDED` | `dangerous` | `response` | No | Clients branching on the concrete type may need to handle a new union member. |
| `UNION_MEMBER_REMOVED` | `breaking` | `request`, `response` | No | A fragment spread targeting the removed member can become invalid. |
