/// Configuration that parameterizes the provider sheets for BSP vs SSP.
class ProviderConfig {
  final String typeName;
  final String typeLabel;
  final BigInt providerType;
  final String requiredPointer;
  final String requiredPointerLabel;
  final List<String> standardPointers;

  const ProviderConfig({
    required this.typeName,
    required this.typeLabel,
    required this.providerType,
    required this.requiredPointer,
    required this.requiredPointerLabel,
    this.standardPointers = const ['region', 'website'],
  });

  static final bsp = ProviderConfig(
    typeName: 'BSP',
    typeLabel: 'Blockchain Service Provider',
    providerType: BigInt.zero,
    requiredPointer: 'rpc-url',
    requiredPointerLabel: 'RPC URL',
  );

  static final ssp = ProviderConfig(
    typeName: 'SSP',
    typeLabel: 'Social Service Provider',
    providerType: BigInt.one,
    requiredPointer: 'api-url',
    requiredPointerLabel: 'API URL',
  );
}
