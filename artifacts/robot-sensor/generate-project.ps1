$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$datasetUrl = "https://cdn.uci-ics-mlr-prod.aws.uci.edu/240/human%2Bactivity%2Brecognition%2Busing%2Bsmartphones.zip"
$selectedDataPath = Join-Path $projectDir "selected-sensor-windows.csv"
$featureReferencePath = Join-Path $projectDir "selected-feature-reference.csv"
$activitySummaryPath = Join-Path $projectDir "activity-summary.csv"
$resultsPath = Join-Path $projectDir "model-results.csv"
$confusionPath = Join-Path $projectDir "best-model-confusion-matrix.csv"
$reportPath = Join-Path $projectDir "project-report.md"
$countChartPath = Join-Path $projectDir "activity-counts.svg"
$motionChartPath = Join-Path $projectDir "motion-score.svg"
$accuracyChartPath = Join-Path $projectDir "model-accuracy.svg"

$tempRoot = Join-Path $env:TEMP ("robot-sensor-project-" + [guid]::NewGuid().ToString())
$tempZip = Join-Path $tempRoot "uci-har.zip"
$extractRoot = Join-Path $tempRoot "extract"

New-Item -ItemType Directory -Force $tempRoot | Out-Null
New-Item -ItemType Directory -Force $extractRoot | Out-Null

try {
  Invoke-WebRequest -Uri $datasetUrl -OutFile $tempZip
  Expand-Archive -Path $tempZip -DestinationPath $extractRoot -Force

  $datasetRoot = Join-Path $extractRoot "UCI HAR Dataset"
  if (-not (Test-Path $datasetRoot)) {
    $nestedZip = Join-Path $extractRoot "UCI HAR Dataset.zip"
    if (Test-Path $nestedZip) {
      Expand-Archive -Path $nestedZip -DestinationPath $extractRoot -Force
    }
  }
  $datasetRoot = Join-Path $extractRoot "UCI HAR Dataset"

  $selectedFeatures = @(
    [pscustomobject]@{ key = "body_acc_mean_x"; source = "tBodyAcc-mean()-X"; label = "Body acceleration mean X" },
    [pscustomobject]@{ key = "body_acc_mean_y"; source = "tBodyAcc-mean()-Y"; label = "Body acceleration mean Y" },
    [pscustomobject]@{ key = "body_acc_mean_z"; source = "tBodyAcc-mean()-Z"; label = "Body acceleration mean Z" },
    [pscustomobject]@{ key = "body_acc_std_x"; source = "tBodyAcc-std()-X"; label = "Body acceleration std X" },
    [pscustomobject]@{ key = "body_acc_std_y"; source = "tBodyAcc-std()-Y"; label = "Body acceleration std Y" },
    [pscustomobject]@{ key = "body_acc_std_z"; source = "tBodyAcc-std()-Z"; label = "Body acceleration std Z" },
    [pscustomobject]@{ key = "body_gyro_mean_x"; source = "tBodyGyro-mean()-X"; label = "Body gyroscope mean X" },
    [pscustomobject]@{ key = "body_gyro_mean_y"; source = "tBodyGyro-mean()-Y"; label = "Body gyroscope mean Y" },
    [pscustomobject]@{ key = "body_gyro_mean_z"; source = "tBodyGyro-mean()-Z"; label = "Body gyroscope mean Z" },
    [pscustomobject]@{ key = "body_gyro_std_x"; source = "tBodyGyro-std()-X"; label = "Body gyroscope std X" },
    [pscustomobject]@{ key = "body_gyro_std_y"; source = "tBodyGyro-std()-Y"; label = "Body gyroscope std Y" },
    [pscustomobject]@{ key = "body_gyro_std_z"; source = "tBodyGyro-std()-Z"; label = "Body gyroscope std Z" },
    [pscustomobject]@{ key = "gravity_acc_mean_x"; source = "tGravityAcc-mean()-X"; label = "Gravity acceleration mean X" },
    [pscustomobject]@{ key = "gravity_acc_mean_y"; source = "tGravityAcc-mean()-Y"; label = "Gravity acceleration mean Y" },
    [pscustomobject]@{ key = "gravity_acc_mean_z"; source = "tGravityAcc-mean()-Z"; label = "Gravity acceleration mean Z" },
    [pscustomobject]@{ key = "body_acc_mag_std"; source = "tBodyAccMag-std()"; label = "Body acceleration magnitude std" },
    [pscustomobject]@{ key = "body_gyro_mag_std"; source = "tBodyGyroMag-std()"; label = "Body gyroscope magnitude std" },
    [pscustomobject]@{ key = "body_gyro_jitter_std"; source = "tBodyGyroJerkMag-std()"; label = "Body gyroscope jerk magnitude std" }
  )

  $activityColorMap = @{
    "WALKING" = "#22d3ee"
    "WALKING_UPSTAIRS" = "#60a5fa"
    "WALKING_DOWNSTAIRS" = "#f472b6"
    "SITTING" = "#f59e0b"
    "STANDING" = "#8b5cf6"
    "LAYING" = "#34d399"
    "Baseline" = "#8b5cf6"
    "Centroid" = "#22d3ee"
    "Prototype 3-NN" = "#f472b6"
  }

  function Get-Mean {
    param([double[]]$Values)

    if ($Values.Count -eq 0) {
      return 0.0
    }

    return ($Values | Measure-Object -Average).Average
  }

  function Get-StdDev {
    param([double[]]$Values)

    if ($Values.Count -le 1) {
      return 1.0
    }

    $mean = Get-Mean -Values $Values
    $variance = 0.0

    foreach ($value in $Values) {
      $variance += [math]::Pow($value - $mean, 2)
    }

    $stdDev = [math]::Sqrt($variance / ($Values.Count - 1))

    if ($stdDev -eq 0) {
      return 1.0
    }

    return $stdDev
  }

  function Get-Distance {
    param(
      [double[]]$Left,
      [double[]]$Right
    )

    $sum = 0.0

    for ($i = 0; $i -lt $Left.Count; $i++) {
      $delta = $Left[$i] - $Right[$i]
      $sum += $delta * $delta
    }

    return [math]::Sqrt($sum)
  }

  function New-BarChartSvg {
    param(
      [string]$Title,
      [object[]]$Items,
      [string]$LabelProperty,
      [string]$ValueProperty,
      [string]$OutputPath,
      [hashtable]$ColorMap,
      [string]$ValueSuffix = "",
      [int]$Decimals = 0
    )

    $width = 900
    $height = 450
    $leftPadding = 90
    $rightPadding = 30
    $topPadding = 76
    $bottomPadding = 92
    $plotWidth = $width - $leftPadding - $rightPadding
    $plotHeight = $height - $topPadding - $bottomPadding
    $maxValue = [double](($Items | Measure-Object -Property $ValueProperty -Maximum).Maximum)

    if ($maxValue -le 0) {
      $maxValue = 1.0
    }

    $slotWidth = $plotWidth / [math]::Max($Items.Count, 1)
    $barWidth = [math]::Min(104, $slotWidth * 0.56)
    $barElements = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $Items.Count; $i++) {
      $item = $Items[$i]
      $label = [string]$item.$LabelProperty
      $value = [double]$item.$ValueProperty
      $barHeight = ($value / $maxValue) * $plotHeight
      $x = $leftPadding + ($slotWidth * $i) + (($slotWidth - $barWidth) / 2)
      $y = $topPadding + ($plotHeight - $barHeight)
      $color = if ($ColorMap.ContainsKey($label)) { $ColorMap[$label] } else { "#8b5cf6" }
      $displayValue = [math]::Round($value, $Decimals).ToString("F$Decimals")
      $safeLabel = $label.Replace("_", "_ ")

      [void]$barElements.Add("<rect x='$x' y='$y' width='$barWidth' height='$barHeight' rx='18' fill='$color' opacity='0.95' />")
      [void]$barElements.Add("<text x='" + ($x + ($barWidth / 2)) + "' y='" + ($y - 10) + "' text-anchor='middle' fill='#f9f7ff' font-size='16' font-weight='700'>$displayValue$ValueSuffix</text>")
      [void]$barElements.Add("<text x='" + ($x + ($barWidth / 2)) + "' y='" + ($topPadding + $plotHeight + 28) + "' text-anchor='middle' fill='#d7d0f2' font-size='14'>$safeLabel</text>")
    }

    $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" role="img" aria-labelledby="chart-title">
  <title id="chart-title">$Title</title>
  <rect width="$width" height="$height" rx="28" fill="#18123b" />
  <text x="$leftPadding" y="42" fill="#f9f7ff" font-size="26" font-weight="800">$Title</text>
  <line x1="$leftPadding" y1="$topPadding" x2="$leftPadding" y2="$(($topPadding + $plotHeight))" stroke="#7964d8" stroke-width="2" opacity="0.55" />
  <line x1="$leftPadding" y1="$(($topPadding + $plotHeight))" x2="$(($leftPadding + $plotWidth))" y2="$(($topPadding + $plotHeight))" stroke="#7964d8" stroke-width="2" opacity="0.55" />
  <text x="24" y="$($topPadding + 6)" fill="#d7d0f2" font-size="14">$([math]::Round($maxValue, $Decimals).ToString("F$Decimals"))$ValueSuffix</text>
  <text x="38" y="$(($topPadding + $plotHeight + 6))" fill="#d7d0f2" font-size="14">0$ValueSuffix</text>
  $([string]::Join("`n  ", $barElements))
</svg>
"@

    Set-Content -Path $OutputPath -Value $svg
  }

  function Get-EvenSample {
    param(
      [object[]]$Rows,
      [int]$Count
    )

    if ($Rows.Count -le $Count) {
      return @($Rows | ForEach-Object { $_ })
    }

    $result = New-Object System.Collections.Generic.List[object]
    $step = $Rows.Count / [double]$Count

    for ($i = 0; $i -lt $Count; $i++) {
      $index = [math]::Floor($i * $step)
      [void]$result.Add($Rows[$index])
    }

    return @($result | ForEach-Object { $_ })
  }

  $activityMap = @{}
  foreach ($line in [System.IO.File]::ReadLines((Join-Path $datasetRoot "activity_labels.txt"))) {
    $parts = $line.Trim() -split "\s+"
    $activityMap[[int]$parts[0]] = $parts[1]
  }

  $featureIndexMap = @{}
  foreach ($line in [System.IO.File]::ReadLines((Join-Path $datasetRoot "features.txt"))) {
    $parts = $line.Trim() -split "\s+", 2
    $featureIndexMap[$parts[1]] = ([int]$parts[0]) - 1
  }

  foreach ($feature in $selectedFeatures) {
    $feature | Add-Member -NotePropertyName index -NotePropertyValue $featureIndexMap[$feature.source]
  }

  function Import-HarSplit {
    param(
      [string]$DatasetRoot,
      [string]$SplitName,
      [object[]]$SelectedFeatures,
      [hashtable]$ActivityMap
    )

    $xPath = Join-Path $DatasetRoot "$SplitName\X_$SplitName.txt"
    $yPath = Join-Path $DatasetRoot "$SplitName\y_$SplitName.txt"
    $subjectPath = Join-Path $DatasetRoot "$SplitName\subject_$SplitName.txt"

    $xLines = Get-Content $xPath
    $yLines = Get-Content $yPath
    $subjectLines = Get-Content $subjectPath
    $rows = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $xLines.Count; $i++) {
      $tokens = $xLines[$i].Trim() -split "\s+"
      $activity = $ActivityMap[[int]$yLines[$i]]
      $properties = [ordered]@{
        split = $SplitName
        subject = [int]$subjectLines[$i]
        activity = $activity
      }

      foreach ($feature in $SelectedFeatures) {
        $properties[$feature.key] = [double]$tokens[$feature.index]
      }

      $row = [pscustomobject]$properties
      $row | Add-Member -NotePropertyName motion_score -NotePropertyValue (
        [math]::Max(
          0.0,
          1.0 + (
            $row.body_acc_std_x +
            $row.body_acc_std_y +
            $row.body_acc_std_z +
            $row.body_gyro_std_x +
            $row.body_gyro_std_y +
            $row.body_gyro_std_z
          ) / 6.0
        )
      )

      [void]$rows.Add($row)
    }

    return @($rows | ForEach-Object { $_ })
  }

  $trainRows = Import-HarSplit -DatasetRoot $datasetRoot -SplitName "train" -SelectedFeatures $selectedFeatures -ActivityMap $activityMap
  $testRows = Import-HarSplit -DatasetRoot $datasetRoot -SplitName "test" -SelectedFeatures $selectedFeatures -ActivityMap $activityMap
  $allRows = @($trainRows + $testRows)

  $allRows | Export-Csv -NoTypeInformation -Path $selectedDataPath

  @(
    $selectedFeatures | ForEach-Object {
      [pscustomobject]@{
        key = $_.key
        source_feature = $_.source
        label = $_.label
      }
    }
  ) | Export-Csv -NoTypeInformation -Path $featureReferencePath

  $activityOrder = @(
    "WALKING",
    "WALKING_UPSTAIRS",
    "WALKING_DOWNSTAIRS",
    "SITTING",
    "STANDING",
    "LAYING"
  )

  $activitySummary = @(
    $activityOrder | ForEach-Object {
      $activityName = $_
      $groupRows = @($allRows | Where-Object { $_.activity -eq $activityName })
      [pscustomobject]@{
        activity = $activityName
        count = $groupRows.Count
        avg_motion_score = [math]::Round((Get-Mean -Values @($groupRows | ForEach-Object { [double]$_.motion_score })), 3)
        avg_acc_std = [math]::Round((Get-Mean -Values @($groupRows | ForEach-Object { ([math]::Abs($_.body_acc_std_x) + [math]::Abs($_.body_acc_std_y) + [math]::Abs($_.body_acc_std_z)) / 3.0 })), 3)
      }
    }
  )

  $activitySummary | Export-Csv -NoTypeInformation -Path $activitySummaryPath

  $featureKeys = @($selectedFeatures | ForEach-Object { $_.key })
  $featureStats = @{}

  foreach ($key in $featureKeys) {
    $values = @($trainRows | ForEach-Object { [double]$_.$key })
    $featureStats[$key] = @{
      mean = Get-Mean -Values $values
      std = Get-StdDev -Values $values
    }
  }

  function Get-NormalizedVector {
    param(
      [pscustomobject]$Row,
      [string[]]$FeatureKeys,
      [hashtable]$FeatureStats
    )

    $vector = New-Object double[] $FeatureKeys.Count

    for ($i = 0; $i -lt $FeatureKeys.Count; $i++) {
      $key = $FeatureKeys[$i]
      $stats = $FeatureStats[$key]
      $vector[$i] = (([double]$Row.$key) - $stats.mean) / $stats.std
    }

    return $vector
  }

  $normalizedTrainRows = @(
    $trainRows | ForEach-Object {
      [pscustomobject]@{
        activity = $_.activity
        vector = Get-NormalizedVector -Row $_ -FeatureKeys $featureKeys -FeatureStats $featureStats
      }
    }
  )

  $centroids = @{}
  foreach ($group in ($normalizedTrainRows | Group-Object activity)) {
    $centroid = New-Object double[] $featureKeys.Count

    foreach ($row in $group.Group) {
      for ($i = 0; $i -lt $featureKeys.Count; $i++) {
        $centroid[$i] += $row.vector[$i]
      }
    }

    for ($i = 0; $i -lt $featureKeys.Count; $i++) {
      $centroid[$i] = $centroid[$i] / $group.Count
    }

    $centroids[$group.Name] = $centroid
  }

  $prototypeRows = New-Object System.Collections.Generic.List[object]
  foreach ($activityName in $activityOrder) {
    $activityRows = @($normalizedTrainRows | Where-Object { $_.activity -eq $activityName })
    foreach ($row in (Get-EvenSample -Rows $activityRows -Count 60)) {
      [void]$prototypeRows.Add($row)
    }
  }
  $prototypeRows = @($prototypeRows | ForEach-Object { $_ })

  function Predict-NearestCentroid {
    param(
      [double[]]$Vector,
      [hashtable]$Centroids
    )

    $bestLabel = ""
    $bestDistance = [double]::PositiveInfinity

    foreach ($label in $Centroids.Keys) {
      $distance = Get-Distance -Left $Vector -Right $Centroids[$label]
      if ($distance -lt $bestDistance) {
        $bestDistance = $distance
        $bestLabel = $label
      }
    }

    return $bestLabel
  }

  function Predict-NearestNeighbor {
    param(
      [double[]]$Vector,
      [object[]]$Prototypes,
      [int]$NeighborCount = 3
    )

    $scored = New-Object System.Collections.Generic.List[object]

    foreach ($prototype in $Prototypes) {
      $distance = Get-Distance -Left $Vector -Right $prototype.vector
      [void]$scored.Add([pscustomobject]@{
        activity = $prototype.activity
        distance = $distance
      })
    }

    $nearest = @(
      $scored |
        Sort-Object distance |
        Select-Object -First $NeighborCount
    )

    return (
      $nearest |
        Group-Object activity |
        Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Name"; Descending = $false } |
        Select-Object -First 1
    ).Name
  }

  function Evaluate-Model {
    param(
      [string]$Name,
      [string]$ShortLabel,
      [object[]]$Rows,
      [scriptblock]$Predictor
    )

    $predictions = New-Object System.Collections.Generic.List[object]
    $correct = 0

    foreach ($row in $Rows) {
      $vector = Get-NormalizedVector -Row $row -FeatureKeys $featureKeys -FeatureStats $featureStats
      $predicted = & $Predictor $vector

      if ($predicted -eq $row.activity) {
        $correct++
      }

      [void]$predictions.Add([pscustomobject]@{
        actual = $row.activity
        predicted = $predicted
      })
    }

    return [pscustomobject]@{
      model = $Name
      short_label = $ShortLabel
      correct = $correct
      total = $Rows.Count
      accuracy = ([double]$correct) / ([double]$Rows.Count)
      predictions = @($predictions | ForEach-Object { $_ })
    }
  }

  $majorityActivity = ($trainRows | Group-Object activity | Sort-Object Count -Descending | Select-Object -First 1).Name

  $baselineResult = Evaluate-Model -Name "Majority activity baseline" -ShortLabel "Baseline" -Rows $testRows -Predictor {
    param($vector)
    return $majorityActivity
  }

  $centroidResult = Evaluate-Model -Name "Nearest centroid classifier" -ShortLabel "Centroid" -Rows $testRows -Predictor {
    param($vector)
    return Predict-NearestCentroid -Vector $vector -Centroids $centroids
  }

  $prototypeResult = Evaluate-Model -Name "Prototype 3-nearest-neighbor classifier" -ShortLabel "Prototype 3-NN" -Rows $testRows -Predictor {
    param($vector)
    return Predict-NearestNeighbor -Vector $vector -Prototypes $prototypeRows -NeighborCount 3
  }

  $allResults = @($baselineResult, $centroidResult, $prototypeResult)
  $bestResult = $allResults | Sort-Object accuracy -Descending | Select-Object -First 1

  $resultRows = @(
    [pscustomobject]@{
      model = $baselineResult.model
      short_label = $baselineResult.short_label
      accuracy_percent = [math]::Round($baselineResult.accuracy * 100, 1)
      correct_predictions = $baselineResult.correct
      total_test_samples = $baselineResult.total
      notes = "Always predicts $majorityActivity."
    },
    [pscustomobject]@{
      model = $centroidResult.model
      short_label = $centroidResult.short_label
      accuracy_percent = [math]::Round($centroidResult.accuracy * 100, 1)
      correct_predictions = $centroidResult.correct
      total_test_samples = $centroidResult.total
      notes = "Uses class centers built from the full training split."
    },
    [pscustomobject]@{
      model = $prototypeResult.model
      short_label = $prototypeResult.short_label
      accuracy_percent = [math]::Round($prototypeResult.accuracy * 100, 1)
      correct_predictions = $prototypeResult.correct
      total_test_samples = $prototypeResult.total
      notes = "Compares each test window to 60 representative training windows per activity using 3 nearest neighbors."
    }
  )

  $resultRows | Export-Csv -NoTypeInformation -Path $resultsPath

  $confusionRows = foreach ($actualActivity in $activityOrder) {
    foreach ($predictedActivity in $activityOrder) {
      [pscustomobject]@{
        actual_activity = $actualActivity
        predicted_activity = $predictedActivity
        count = @(
          $bestResult.predictions | Where-Object {
            $_.actual -eq $actualActivity -and $_.predicted -eq $predictedActivity
          }
        ).Count
      }
    }
  }

  $confusionRows | Export-Csv -NoTypeInformation -Path $confusionPath

  New-BarChartSvg `
    -Title "Activity Window Counts" `
    -Items $activitySummary `
    -LabelProperty "activity" `
    -ValueProperty "count" `
    -OutputPath $countChartPath `
    -ColorMap $activityColorMap

  New-BarChartSvg `
    -Title "Average Motion Score by Activity" `
    -Items $activitySummary `
    -LabelProperty "activity" `
    -ValueProperty "avg_motion_score" `
    -OutputPath $motionChartPath `
    -ColorMap $activityColorMap `
    -Decimals 3

  New-BarChartSvg `
    -Title "Model Accuracy Comparison" `
    -Items $resultRows `
    -LabelProperty "short_label" `
    -ValueProperty "accuracy_percent" `
    -OutputPath $accuracyChartPath `
    -ColorMap $activityColorMap `
    -ValueSuffix "%" `
    -Decimals 1

  $report = @"
# Robot Sensor Data Classification

## Title

Robot Sensor Data Classification

## Objective

Use a public inertial-sensor dataset to classify motion and posture states, then
present the workflow as a shareable machine learning project with downloadable
results and visual summaries.

## Process

1. Downloaded the UCI Human Activity Recognition Using Smartphones dataset.
2. Selected 18 accelerometer and gyroscope summary features that describe motion.
3. Preserved the official train and test split from the source dataset.
4. Compared a majority baseline, a nearest centroid classifier, and a prototype
   3-nearest-neighbor classifier.
5. Exported charts, comparison tables, and project files for the portfolio.

## Tools

- PowerShell
- CSV data processing
- Static SVG chart generation
- GitHub Pages compatible HTML, Markdown, and downloadable assets

## Value Proposition

This project demonstrates my ability to work with sensor-oriented data, structure
repeatable analysis workflows, and connect machine learning outputs to a
robotics-adjacent use case that is easy to review publicly.

## Dataset Snapshot

- Source dataset: UCI Human Activity Recognition Using Smartphones
- Subjects: 30
- Activities: 6
- Training windows: $($trainRows.Count)
- Test windows: $($testRows.Count)
- Selected features: $($selectedFeatures.Count)

## Activity Labels

- WALKING
- WALKING_UPSTAIRS
- WALKING_DOWNSTAIRS
- SITTING
- STANDING
- LAYING

## Model Results

| Model | Accuracy | Correct / Total |
| --- | ---: | ---: |
| Majority activity baseline | $($resultRows[0].accuracy_percent)% | $($resultRows[0].correct_predictions) / $($resultRows[0].total_test_samples) |
| Nearest centroid classifier | $($resultRows[1].accuracy_percent)% | $($resultRows[1].correct_predictions) / $($resultRows[1].total_test_samples) |
| Prototype 3-nearest-neighbor classifier | $($resultRows[2].accuracy_percent)% | $($resultRows[2].correct_predictions) / $($resultRows[2].total_test_samples) |

## Key Takeaways

- Sensor windows describing walking and posture can be separated effectively with
  a relatively small number of engineered features.
- The nearest centroid model offers an interpretable summary of activity classes.
- The prototype 3-nearest-neighbor model captured local motion patterns and
  achieved the best accuracy in this project.

## Deliverables Included

- selected-sensor-windows.csv
- selected-feature-reference.csv
- activity-summary.csv
- model-results.csv
- best-model-confusion-matrix.csv
- activity-counts.svg
- motion-score.svg
- model-accuracy.svg
- generate-project.ps1

## Visuals

![Activity window counts](activity-counts.svg)

![Average motion score by activity](motion-score.svg)

![Model accuracy comparison](model-accuracy.svg)
"@

  Set-Content -Path $reportPath -Value $report
}
finally {
  if (Test-Path $tempRoot) {
    Remove-Item -Recurse -Force $tempRoot
  }
}
