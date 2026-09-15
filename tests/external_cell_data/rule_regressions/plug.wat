(component
  (core module $m
    (func (export "answer") (result i32) i32.const 42)
  )
  (core instance $i (instantiate $m))
  (func $answer (result u32) (canon lift (core func $i "answer")))
  (instance $api (export "answer" (func $answer)))
  (export "api" (instance $api))
)
