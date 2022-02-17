package main

import (
	"encoding/json"
	"io"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/tailscale/hujson"
	"gonum.org/v1/gonum/stat/combin"
)

const DefaultApiVersion = "0.7"
const MetadataIdPrefix = "com.microsoft.devcontainer"
const FeaturesetMetadataId = MetadataIdPrefix + ".featureset"
const FeaturesMetadataId = MetadataIdPrefix + ".features"
const FeatureLayerMetadataId = MetadataIdPrefix + ".feature"
const BuildModeMetadataId = MetadataIdPrefix + ".buildmode"
const OptionMetadataKeyPrefix = "option_"
const BuildpackDirEnvVar = "CNB_BUILDPACK_DIR"
const ContainerImageBuildModeEnvVarName = "BP_DCNB_BUILD_MODE"
const RemoveApplicationFolderOverrideEnvVarName = "BP_DCNB_OMIT_APP_DIR"
const OptionSelectionEnvVarPrefix = "_BUILD_ARG_"
const ProjectTomlOptionSelectionEnvVarPrefix = "BP_CONTAINER_FEATURE_"
const DefaultContainerImageBuildMode = "production"
const DevContainerConfigSubfolder = "/etc/dev-container-features"
const ContainerImageBuildMarkerPath = "/usr/local/" + DevContainerConfigSubfolder + "/dcnb-build-mode"
const DevpackSettingsFilename = "devpack-settings.json"
const BuildModeDevContainerJsonSetting = "buildMode"
const TargetPathDevContainerJsonSetting = "targetPath"

var cachedContainerImageBuildMode = ""

type NonZeroExitError struct {
	ExitCode int
}

func (err NonZeroExitError) Error() string {
	return "Non-zero exit code: " + strconv.FormatInt(int64(err.ExitCode), 10)
}

type FeatureMount struct {
	Source string
	Target string
	Type   string
}

type FeatureOption struct {
	Type        string
	Enum        []string
	Proposals   []string
	Default     interface{}
	Description string
}

type FeatureConfig struct {
	Id           string
	Name         string
	Options      map[string]FeatureOption
	Entrypoint   string
	Privileged   bool
	Init         bool
	ContainerEnv map[string]string
	Mounts       []FeatureMount
	CapAdd       []string
	SecurityOpt  []string
	BuildArg     string
}

type FeaturesJson struct {
	Features []FeatureConfig
}

// Required configuration for processing
type DevpackSettings struct {
	Publisher  string   // aka GitHub Org
	FeatureSet string   // aka GitHub Repository
	Version    string   // Used for version pinning
	ApiVersion string   // Buildpack API version to target
	Stacks     []string // Array of stacks that the buildpack should support
}

// Pull in json as a simple map of maps given the structure
type DevContainerJson struct {
	Features map[string]interface{}
}

type LayerFeatureMetadata struct {
	Id               string
	Version          string
	OptionSelections map[string]string
}

func LoadFeaturesJson(featuresPath string) FeaturesJson {
	// Load devcontainer-features.json or features.json
	if featuresPath == "" {
		featuresPath = os.Getenv(BuildpackDirEnvVar)
	}
	content, err := ioutil.ReadFile(filepath.Join(featuresPath, "devcontainer-features.json"))
	if err != nil {
		log.Fatal(err)
	}
	var featuresJson FeaturesJson
	err = json.Unmarshal(content, &featuresJson)
	if err != nil {
		log.Fatal(err)
	}

	return featuresJson
}

func LoadDevpackSettings(featuresPath string) DevpackSettings {
	if featuresPath == "" {
		featuresPath = os.Getenv(BuildpackDirEnvVar)
	}
	content, err := ioutil.ReadFile(filepath.Join(featuresPath, DevpackSettingsFilename))
	if err != nil {
		log.Fatal(err)
	}
	var jsonContents DevpackSettings
	err = json.Unmarshal(content, &jsonContents)
	if err != nil {
		log.Fatal(err)
	}

	return jsonContents
}

func FindDevContainerJson(applicationFolder string) string {
	// Load devcontainer.json
	if applicationFolder == "" {
		var err error
		applicationFolder, err = os.Getwd()
		if err != nil {
			log.Fatal(err)
		}
	}

	expectedPath := filepath.Join(applicationFolder, ".devcontainer", "devcontainer.json")
	if _, err := os.Stat(expectedPath); err != nil {
		// if file does not exist, try .devcontainer.json instead
		if os.IsNotExist(err) {
			expectedPath = filepath.Join(applicationFolder, ".devcontainer.json")
			if _, err := os.Stat(expectedPath); err != nil {
				if !os.IsNotExist(err) {
					log.Fatal(err)
				}
				return ""
			}
		} else {
			log.Fatal(err)
		}
	}
	return expectedPath
}

func loadDevContainerJsonConent(applicationFolder string) ([]byte, string) {
	devContainerJsonPath := FindDevContainerJson(applicationFolder)
	if devContainerJsonPath == "" {
		return []byte{}, devContainerJsonPath
	}
	content, err := ioutil.ReadFile(devContainerJsonPath)
	if err != nil {
		log.Fatal(err)
	}
	// Strip out comments to enable parsing
	ast, err := hujson.Parse(content)
	if err != nil {
		log.Fatal(err)
	}
	ast.Standardize()
	content = ast.Pack()

	return content, devContainerJsonPath
}

func LoadDevContainerJson(applicationFolder string) (DevContainerJson, string) {
	var devContainerJson DevContainerJson
	content, devContainerJsonPath := loadDevContainerJsonConent(applicationFolder)
	if devContainerJsonPath != "" {
		err := json.Unmarshal(content, &devContainerJson)
		if err != nil {
			log.Fatal(err)
		}

	}
	return devContainerJson, devContainerJsonPath
}

func LoadDevContainerJsonAsMap(applicationFolder string) (map[string]json.RawMessage, string) {
	var jsonMap map[string]json.RawMessage
	content, devContainerJsonPath := loadDevContainerJsonConent(applicationFolder)
	if devContainerJsonPath != "" {
		err := json.Unmarshal(content, &jsonMap)
		if err != nil {
			log.Fatal(err)
		}
	}
	return jsonMap, devContainerJsonPath
}

func GetFeatureScriptPath(buidpackPath string, featureId string, script string) string {
	return filepath.Join(buidpackPath, "features", featureId, "bin", script)
}

func GetContainerImageBuildMode() string {
	if cachedContainerImageBuildMode != "" {
		return cachedContainerImageBuildMode
	}
	cachedContainerImageBuildMode := os.Getenv(ContainerImageBuildModeEnvVarName)
	if cachedContainerImageBuildMode == "" {
		if _, err := os.Stat(ContainerImageBuildMarkerPath); err != nil {
			cachedContainerImageBuildMode = DefaultContainerImageBuildMode
		} else {
			fileBytes, err := os.ReadFile(ContainerImageBuildMarkerPath)
			if err != nil {
				cachedContainerImageBuildMode = DefaultContainerImageBuildMode
			} else {
				cachedContainerImageBuildMode = strings.TrimSpace(string(fileBytes))
			}
		}
	}
	return cachedContainerImageBuildMode
}

func GetBuildEnvironment(feature FeatureConfig, optionSelections map[string]string, additionalVariables map[string]string) []string {
	// Create environment that includes feature build args
	env := append(os.Environ(),
		GetOptionEnvVarName(OptionSelectionEnvVarPrefix, feature.Id, "")+"=true")
	for optionId, selection := range optionSelections {
		if selection != "" {
			env = append(env, GetOptionEnvVarName(OptionSelectionEnvVarPrefix, feature.Id, optionId)+"="+selection)
		}
	}
	for varName, varValue := range additionalVariables {
		env = append(env, GetOptionEnvVarName(OptionSelectionEnvVarPrefix, feature.Id, varName)+"="+varValue)
	}
	log.Println(env)
	return env
}

func GetOptionEnvVarName(prefix string, featureId string, optionId string) string {
	if prefix == "" {
		prefix = OptionSelectionEnvVarPrefix
	}
	featureIdSafe := strings.ReplaceAll(strings.ToUpper(featureId), "-", "_")
	if optionId != "" {
		optionIdSafe := strings.ReplaceAll(strings.ToUpper(optionId), "-", "_")
		return prefix + featureIdSafe + "_" + strings.ToUpper(strings.ReplaceAll(optionIdSafe, "-", "_"))
	}
	return prefix + featureId
}

func GetOptionMetadataKey(optionId string) string {
	return OptionMetadataKeyPrefix + strings.ToLower(strings.ReplaceAll(optionId, "-", "_"))
}

// e.g. chuxel/devcontainer/features/packcli
func GetFullFeatureId(feature FeatureConfig, devpackSettings DevpackSettings, separator string) string {
	if separator == "" {
		separator = "/"
	}
	return devpackSettings.Publisher + separator + devpackSettings.FeatureSet + separator + feature.Id
}

func CpR(sourcePath string, targetFolderPath string) {
	sourceFileInfo, err := os.Stat(sourcePath)
	if err != nil {
		// Return if source path doesn't exist so we can use this with optional files
		return
	}
	// Handle if source is file
	if !sourceFileInfo.IsDir() {
		Cp(sourcePath, targetFolderPath)
		return
	}

	// Otherwise create the directory and scan contents
	toFolderPath := filepath.Join(targetFolderPath, sourceFileInfo.Name())
	os.MkdirAll(toFolderPath, sourceFileInfo.Mode())
	fileInfos, err := ioutil.ReadDir(sourcePath)
	if err != nil {
		log.Fatal(err)
	}
	for _, fileInfo := range fileInfos {
		fromPath := filepath.Join(sourcePath, fileInfo.Name())
		if fileInfo.IsDir() {
			CpR(fromPath, toFolderPath)
		} else {
			Cp(fromPath, toFolderPath)
		}
	}
}

func Cp(sourceFilePath string, targetFolderPath string) {
	sourceFileInfo, err := os.Stat(sourceFilePath)
	if err != nil {
		log.Fatal(err)
	}

	// Make target file
	targetFilePath := filepath.Join(targetFolderPath, sourceFileInfo.Name())
	targetFile, err := os.Create(targetFilePath)
	if err != nil {
		log.Fatal(err)
	}
	// Sync source and target file mode and ownership
	targetFile.Chmod(sourceFileInfo.Mode())
	SyncUIDGID(targetFile, sourceFileInfo)

	// Execute copy
	sourceFile, err := os.Open(sourceFilePath)
	if err != nil {
		log.Fatal(err)
	}
	_, err = io.Copy(targetFile, sourceFile)
	if err != nil {
		log.Fatal(err)
	}
	targetFile.Close()
	sourceFile.Close()
}

func WriteFile(filename string, fileBytes []byte) error {
	file, err := os.OpenFile(filename, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return err
	}
	if _, err = file.Write(fileBytes); err != nil {
		return err
	}
	if err = file.Close(); err != nil {
		return err
	}
	return nil
}

func GetAllCombinations(arraySize int) [][]int {
	combinationList := [][]int{}
	for i := 1; i <= arraySize; i++ {
		combinationList = append(combinationList, combin.Combinations(arraySize, i)...)
	}
	return combinationList
}
