(component
  (type $api-type (instance (export "answer" (func (result u32)))))
  (import "api" (instance $api (type $api-type)))
  (export "api" (instance $api))
)
