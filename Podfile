source 'https://github.com/cocoapods/specs.git'
use_frameworks!

load 'Podfile.include'

$tunnelkit_name = 'TunnelKit'
$tunnelkit_specs = ['Protocols/OpenVPN', 'Extra/LZO']

def shared_pods
    #pod_version $tunnelkit_name, $tunnelkit_specs, '~> 2.0.1'
    pod_git $tunnelkit_name, $tunnelkit_specs, '7ba0225'
    #pod_path $tunnelkit_name, $tunnelkit_specs, '..'
   
end

target 'VPNCore' do
    platform :ios, '11.0'
    shared_pods
	pod 'MBProgressHUD'
pod 'Convenience', :git => 'https://github.com/keeshux/convenience.git'
pod 'Kvitto'
pod 'SSZipArchive' 
end

