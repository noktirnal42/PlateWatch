# Model registry manifest — contract between `scripts/convert_models.py`,
# the Swift `ModelManager` (VehicleML), and the releases/CDN that hosts
# compiled models. Weights are NEVER committed to git (.gitignore).
#
# Field contract is `VehicleML.ModelRegistryEntry` (Codable).
# sha256 pins the *uploaded artifact*; convert_models.py updates entries
# after conversion ("REPLACE_AT_CONVERSION_TIME" = pending).
