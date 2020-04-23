Pod::Spec.new do |spec|
  spec.name = "VPNCore"
  spec.version = "1.0.2"
  spec.summary = "Sample framework"
  spec.homepage = "https://github.com/sundaleek/VPNCore"
  spec.license = "MIT"
  spec.authors = {
    "Sundaleek" => 'sundaleek@gmail.com',
    "thoughtbot" => nil,
  }

  spec.source = { :git => "https://github.com/sundaleek/VPNCore.git", :tag => spec.version.to_s }
  spec.platform     = :ios
  spec.ios.deployment_target = "9.1"
  spec.source_files = "VPNCore/*.swift"

end
