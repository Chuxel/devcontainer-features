package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"

	"github.com/buildpacks/libcnb"
)

type FeatureBuilder struct {
	// Implements libcnb.Builder
	// Build(context libcnb.BuildContext) (libcnb.BuildResult, error)
}

type FeatureLayerContributor struct {
	// Implements libcnb.LayerContributor
	// Contribute(context libcnb.ContributeContext) (libcnb.Layer, error)
	// Name() string

	// FullFeatureId() string
	Feature          FeatureConfig
	DevpackSettings  DevpackSettings
	LayerTypes       libcnb.LayerTypes
	Context          libcnb.BuildContext
	OptionSelections map[string]string
}

// Implementation of libcnb.Builder.Build
func (fb FeatureBuilder) Build(context libcnb.BuildContext) (libcnb.BuildResult, error) {
	log.Println("Devpack path:", context.Buildpack.Path)
	log.Println("Application path:", context.Application.Path)
	log.Println("Number of plan entries:", len(context.Plan.Entries))
	log.Println("Env:", os.Environ())

	var result libcnb.BuildResult

	// Load devcontainer.json, features.json, buildpack settings
	devpackSettings := LoadDevpackSettings(context.Buildpack.Path)
	featuresJson := LoadFeaturesJson(context.Buildpack.Path)
	log.Println("Number of features in Devpack:", len(featuresJson.Features))

	// Process each feature if it is in the buildpack plan in the order they appear in features.json
	for _, feature := range featuresJson.Features {
		shouldAddLayer, layerContributor := createLayerContributorForFeature(feature, devpackSettings, context.Plan)
		if shouldAddLayer {
			layerContributor.Context = context
			result.Layers = append(result.Layers, layerContributor)
			// TODO: Handle entrypoints? Or leave this to devcontainer CLI?
		}
	}
	// Generate any unmet entries
	for _, entry := range context.Plan.Entries {
		met := false
		for _, layer := range result.Layers {
			if entry.Name == layer.(FeatureLayerContributor).FullFeatureId() {
				met = true
				break
			}
		}
		if !met {
			result.Unmet = append(result.Unmet, libcnb.UnmetPlanEntry{Name: entry.Name})
		}
	}
	log.Printf("Number of layer contributors: %d", len(result.Layers))
	log.Printf("Unmet entries: %d", len(result.Unmet))

	buildMode := GetContainerImageBuildMode()

	result.Labels = append(result.Labels, libcnb.Label{
		Key:   BuildModeMetadataId,
		Value: buildMode,
	})

	// If we're in devcontainer mode, delete the app folder contents so they are omitted in the output.
	// This would not affect detection logic because any detect steps will have already run by this point.
	if buildMode == "devcontainer" && os.Getenv(RemoveApplicationFolderOverrideEnvVarName) != "false" {
		log.Println("(*) Removing contents at", context.Application.Path, "so they are not in the resulting output.")
		entries, err := os.ReadDir(context.Application.Path)
		if err != nil {
			log.Fatal("Failed to get directory contents in", context.Application.Path, "-", err)
		}
		// Copy devcontainer.json so it can be used for subsequent processing
		devContainerJsonFullPath := FindDevContainerJson(context.Application.Path)
		if devContainerJsonFullPath != "" {
			Cp(devContainerJsonFullPath, "/tmp/")
			if filepath.Base(devContainerJsonFullPath) == "devcontainer.json" {
				if os.Rename("/tmp/devcontainer.json", "/tmp/.devcontainer.json"); err != nil {
					log.Fatal("Failed to rename devcontainer.json to .devcontainer.json: ", err)
				}
			}
		}
		for _, entry := range entries {
			if err := os.RemoveAll(filepath.Join(context.Application.Path, entry.Name())); err != nil {
				log.Fatal("Failed to remove", entry.Name(), "-", err)
			}
		}
		// Copy devcontainer.json back
		if devContainerJsonFullPath != "" {
			Cp("/tmp/.devcontainer.json", context.Application.Path)
		}
	} else {
		log.Println("(*) Leaving application folder contents in place.")
	}

	return result, nil
}

func (fc FeatureLayerContributor) FullFeatureId() string {
	// e.g. chuxel-devcontainer-features-packcli
	return GetFullFeatureId(fc.Feature, fc.DevpackSettings, "/")
}

// Implementation of libcnb.LayerContributor.Name
func (fc FeatureLayerContributor) Name() string {
	// e.g. packcli
	return fc.Feature.Id
}

// Implementation of libcnb.LayerContributor.Contribute
func (fc FeatureLayerContributor) Contribute(layer libcnb.Layer) (libcnb.Layer, error) {
	var err error
	// Check if acquire script for feature exists, exit otherwise
	acquireScriptPath := GetFeatureScriptPath(fc.Context.Buildpack.Path, fc.Feature.Id, "acquire")
	_, err = os.Stat(acquireScriptPath)
	if err != nil {
		log.Printf("- Skipping feature %s. No acquire script.", fc.FullFeatureId())
		return layer, nil
	}

	// Always set targetPath to the layer path we were handed
	fc.OptionSelections["targetPath"] = layer.Path
	// Get build environment based on set options
	env := GetBuildEnvironment(fc.Feature, fc.OptionSelections, map[string]string{
		"PROFILE_D":    filepath.Join(layer.Path, "profile.d"),
		"EXEC_D":       filepath.Join(layer.Path, "exec.d"),
		"ENTRYPOINT_D": filepath.Join(layer.Path, "entrypoint.d"),
	})

	// Run acquire script (if it exists)
	var acquireExecuted bool
	if acquireExecuted, err = fc.executeFeatureScript("acquire", env); err != nil {
		log.Fatal("Failed to execute acquire script for feature", fc.FullFeatureId(), ": ", err)
	}

	// Copy in devcontainer-feature.json for future reference
	featureScriptBase := filepath.Join(layer.Path, DevContainerConfigSubfolder, "feature-config")
	var featureBytes []byte
	if featureBytes, err = json.Marshal(fc.Feature); err != nil {
		log.Fatal("Failed to marshal feature config to json: ", err)
	}

	// Wire in configure script (if it exists) - we'll fire this in post processing
	configureExists := false
	configureScriptPath := GetFeatureScriptPath(fc.Context.Buildpack.Path, fc.Feature.Id, "configure")
	if _, err := os.Stat(configureScriptPath); err == nil {
		log.Println("Setting up configure script for post processing...")
		configureExists = true
		// Copy configure script into layer if it exists
		featureScriptFolder := filepath.Join(featureScriptBase, "features")
		if err := os.MkdirAll(featureScriptFolder, 0777); err != nil {
			log.Fatal("Could not create feature folder: ", err)
		}
		CpR(filepath.Join(fc.Context.Buildpack.Path, "features", fc.Feature.Id), featureScriptFolder)
		CpR(filepath.Join(fc.Context.Buildpack.Path, "common"), featureScriptBase)
		// output an environment file that we can source later
		envFileContents := ""
		for _, line := range env {
			envFileContents += line + "\n"
		}
		WriteFile(filepath.Join(featureScriptFolder, fc.Feature.Id, "devcontainer-features.env"), []byte(envFileContents))
	}

	// If there's nothing to do, exit
	if !acquireExecuted && !configureExists {
		return layer, nil
	}

	// Add ID and option selections to layer metadata, add to LayerContributor
	layer.Metadata = make(map[string]interface{})
	layer.Metadata[FeatureLayerMetadataId] = LayerFeatureMetadata{
		Id:               fc.FullFeatureId(),
		Version:          fc.DevpackSettings.Version,
		OptionSelections: fc.OptionSelections,
	}

	// TODO: Process containerEnv? Results in dupes if something like PATH is updated, but can be needed in production mode.
	//if fc.Feature.ContainerEnv != nil && len(fc.Feature.ContainerEnv) > 0 {
	//	processContainerEnv(fc.Feature.ContainerEnv, layer)
	//}

	// Finally, update layer types based on what was detected when created
	layer.LayerTypes = fc.LayerTypes

	return layer, nil
}

// See if the build plan includes an entry for this feature. If so, return a LayerContributor for it
func createLayerContributorForFeature(feature FeatureConfig, devpackSettings DevpackSettings, plan libcnb.BuildpackPlan) (bool, FeatureLayerContributor) {
	layerContributor := FeatureLayerContributor{Feature: feature, DevpackSettings: devpackSettings}
	// See if detect said should provide this feature
	for _, entry := range plan.Entries {
		// See if this entry is for this feature
		fullFeatureId := layerContributor.FullFeatureId()
		if entry.Name == fullFeatureId {
			log.Printf("- Entry for %s found", fullFeatureId)

			// If entry metadata contains the build, Launch, or cache keys, set
			// it on the LayerTypes object using reflection, otherwise set to true
			var layerTypes libcnb.LayerTypes
			for _, key := range []string{"Build", "Launch", "Cache"} {
				value, containsKey := entry.Metadata[strings.ToLower(key)]
				field := reflect.ValueOf(&layerTypes).Elem().FieldByName(key)
				if containsKey {
					field.Set(reflect.ValueOf(value.(bool)))
				} else {
					// default is true
					field.Set(reflect.ValueOf(true))
				}
			}
			layerContributor.LayerTypes = layerTypes
			// See if feature options were passed using option_<optionname> from
			// either the "detect" command or from a dependant buildpack
			optionSelections := make(map[string]string)
			for optionId := range feature.Options {
				selection, containsKey := entry.Metadata[GetOptionMetadataKey(optionId)]
				if containsKey {
					optionSelections[optionId] = fmt.Sprint(selection)
				}
			}
			// Always parse buildMode. If not set by detect (e.g. was required by another Buildpack), detect the buildMode instead
			buildMode := entry.Metadata[GetOptionMetadataKey(BuildModeDevContainerJsonSetting)]
			if buildMode == nil {
				buildMode = GetContainerImageBuildMode()
			}
			optionSelections[BuildModeDevContainerJsonSetting] = fmt.Sprint(buildMode)
			layerContributor.OptionSelections = optionSelections

			return true, layerContributor
		}
	}

	return false, layerContributor
}

func processContainerEnv(containerEnv map[string]string, layer libcnb.Layer) {
	for name, value := range containerEnv {
		before, after, overwrite := processEnvVar(name, value, containerEnv)
		if before != "" || after != "" {
			layer.SharedEnvironment.Prepend(name, "", before)
			layer.SharedEnvironment.Append(name, "", after)
		} else {
			layer.SharedEnvironment.Override(name, overwrite)
		}
	}
}

func processEnvVar(name string, value string, envVars map[string]string) (string, string, string) {
	before := ""
	after := ""
	overwrite := ""

	// Handle self-referencing - handle like ${PATH} or ${containerEnv:PATH}
	selfReplaceString := "${" + name + "}"
	selfRefIndex := strings.Index(value, selfReplaceString)
	if selfRefIndex < 0 {
		selfReplaceString = "${containerEnv:" + name + "}"
		selfRefIndex = strings.Index(value, selfReplaceString)
	}
	if selfRefIndex < 0 {
		overwrite = value
	} else {
		before = value[:selfRefIndex]
		after = value[selfRefIndex+len(selfReplaceString):]
	}

	// Replace other variables set
	for otherVarName, otherVarValue := range envVars {
		if otherVarName != name {
			for _, replaceString := range []string{"${containerEnv:" + otherVarName + "}", "${" + otherVarName + "}"} {
				before = strings.ReplaceAll(before, replaceString, otherVarValue)
				after = strings.ReplaceAll(after, replaceString, otherVarValue)
				overwrite = strings.ReplaceAll(overwrite, replaceString, otherVarValue)
			}
		}
	}

	return before, after, overwrite
}

func (fc FeatureLayerContributor) executeFeatureScript(scriptName string, env []string) (bool, error) {
	scriptPath := GetFeatureScriptPath(fc.Context.Buildpack.Path, fc.Feature.Id, scriptName)
	if _, err := os.Stat(scriptPath); err != nil {
		log.Printf("- Skipping feature %s. No acquire script.", fc.FullFeatureId())
		return false, nil
	}

	// Execute the script
	log.Printf("- Executing %s\n", scriptPath)
	logWriter := log.Writer()
	command := exec.Command(scriptPath)
	command.Env = env
	command.Stdout = logWriter
	command.Stderr = logWriter
	command.Dir = fc.Context.Application.Path

	if err := command.Run(); err != nil {
		return false, err
	}
	exitCode := command.ProcessState.ExitCode()
	if exitCode != 0 {
		log.Printf("Error executing %s. Exit code %d.\n", scriptPath, exitCode)
		return false, NonZeroExitError{ExitCode: exitCode}
	}

	return true, nil
}
