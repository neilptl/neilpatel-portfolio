$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$artifactDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$datasetUrl = "https://raw.githubusercontent.com/allisonhorst/palmerpenguins/master/inst/extdata/penguins.csv"
$datasetPath = Join-Path $artifactDir "penguins.csv"
$reportPath = Join-Path $artifactDir "project-report.md"
$summaryPath = Join-Path $artifactDir "species-summary.csv"
$resultsPath = Join-Path $artifactDir "model-results.csv"
$confusionPath = Join-Path $artifactDir "best-model-confusion-matrix.csv"
$countChartPath = Join-Path $artifactDir "species-counts.svg"
$flipperChartPath = Join-Path $artifactDir "average-flipper-length.svg"
$accuracyChartPath = Join-Path $artifactDir "model-accuracy.svg"

if (-not (Test-Path $datasetPath)) {
  Invoke-WebRequest -Uri $datasetUrl -OutFile $datasetPath
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
  $varianceSum = 0.0

  foreach ($value in $Values) {
    $varianceSum += [math]::Pow($value - $mean, 2)
  }

  $stdDev = [math]::Sqrt($varianceSum / ($Values.Count - 1))

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

  $width = 820
  $height = 420
  $leftPadding = 80
  $rightPadding = 30
  $topPadding = 72
  $bottomPadding = 78
  $plotWidth = $width - $leftPadding - $rightPadding
  $plotHeight = $height - $topPadding - $bottomPadding
  $maxValue = [double](($Items | Measure-Object -Property $ValueProperty -Maximum).Maximum)

  if ($maxValue -le 0) {
    $maxValue = 1.0
  }

  $slotWidth = $plotWidth / [math]::Max($Items.Count, 1)
  $barWidth = [math]::Min(130, $slotWidth * 0.58)
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

    [void]$barElements.Add("<rect x='$x' y='$y' width='$barWidth' height='$barHeight' rx='18' fill='$color' opacity='0.95' />")
    [void]$barElements.Add("<text x='" + ($x + ($barWidth / 2)) + "' y='" + ($y - 10) + "' text-anchor='middle' fill='#f9f7ff' font-size='16' font-weight='700'>$displayValue$ValueSuffix</text>")
    [void]$barElements.Add("<text x='" + ($x + ($barWidth / 2)) + "' y='" + ($topPadding + $plotHeight + 28) + "' text-anchor='middle' fill='#d7d0f2' font-size='16'>$label</text>")
  }

  $svg = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $width $height" role="img" aria-labelledby="chart-title">
  <title id="chart-title">$Title</title>
  <rect width="$width" height="$height" rx="28" fill="#18123b" />
  <text x="$leftPadding" y="38" fill="#f9f7ff" font-size="26" font-weight="800">$Title</text>
  <line x1="$leftPadding" y1="$topPadding" x2="$leftPadding" y2="$(($topPadding + $plotHeight))" stroke="#7964d8" stroke-width="2" opacity="0.55" />
  <line x1="$leftPadding" y1="$(($topPadding + $plotHeight))" x2="$(($leftPadding + $plotWidth))" y2="$(($topPadding + $plotHeight))" stroke="#7964d8" stroke-width="2" opacity="0.55" />
  <text x="24" y="$($topPadding + 6)" fill="#d7d0f2" font-size="14">$([math]::Round($maxValue, $Decimals).ToString("F$Decimals"))$ValueSuffix</text>
  <text x="38" y="$(($topPadding + $plotHeight + 6))" fill="#d7d0f2" font-size="14">0$ValueSuffix</text>
  $([string]::Join("`n  ", $barElements))
</svg>
"@

  Set-Content -Path $OutputPath -Value $svg
}

$rawRows = Import-Csv $datasetPath
$cleanRows = @(
  $rawRows | Where-Object {
    $_.bill_length_mm -ne "NA" -and
    $_.bill_depth_mm -ne "NA" -and
    $_.flipper_length_mm -ne "NA" -and
    $_.body_mass_g -ne "NA" -and
    $_.sex -ne "NA"
  } | ForEach-Object {
    [pscustomobject]@{
      species = $_.species
      island = $_.island
      bill_length_mm = [double]$_.bill_length_mm
      bill_depth_mm = [double]$_.bill_depth_mm
      flipper_length_mm = [double]$_.flipper_length_mm
      body_mass_g = [double]$_.body_mass_g
      sex = $_.sex
      year = [int]$_.year
    }
  }
)

$speciesOrder = @("Adelie", "Chinstrap", "Gentoo")
$speciesColors = @{
  "Adelie" = "#22d3ee"
  "Chinstrap" = "#f472b6"
  "Gentoo" = "#f59e0b"
  "Baseline" = "#8b5cf6"
  "Centroid" = "#22d3ee"
  "1-NN" = "#f472b6"
}

$sortedRows = @(
  $cleanRows | Sort-Object species, year, island, bill_length_mm, flipper_length_mm, body_mass_g
)

$trainRows = New-Object System.Collections.Generic.List[object]
$testRows = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $sortedRows.Count; $i++) {
  if ($i % 5 -eq 0) {
    [void]$testRows.Add($sortedRows[$i])
  }
  else {
    [void]$trainRows.Add($sortedRows[$i])
  }
}

$featureNames = @("bill_length_mm", "bill_depth_mm", "flipper_length_mm", "body_mass_g")
$featureStats = @{}

foreach ($feature in $featureNames) {
  $values = @($trainRows | ForEach-Object { [double]$_.$feature })
  $featureStats[$feature] = @{
    mean = Get-Mean -Values $values
    std = Get-StdDev -Values $values
  }
}

function Get-NormalizedVector {
  param(
    [pscustomobject]$Row,
    [string[]]$FeatureNames,
    [hashtable]$FeatureStats
  )

  $vector = New-Object double[] $FeatureNames.Count

  for ($i = 0; $i -lt $FeatureNames.Count; $i++) {
    $feature = $FeatureNames[$i]
    $stats = $FeatureStats[$feature]
    $vector[$i] = (([double]$Row.$feature) - $stats.mean) / $stats.std
  }

  return $vector
}

$trainingVectors = @(
  $trainRows | ForEach-Object {
    [pscustomobject]@{
      species = $_.species
      vector = Get-NormalizedVector -Row $_ -FeatureNames $featureNames -FeatureStats $featureStats
    }
  }
)

$centroids = @{}

foreach ($group in ($trainingVectors | Group-Object species)) {
  $centroid = New-Object double[] $featureNames.Count

  foreach ($entry in $group.Group) {
    for ($i = 0; $i -lt $featureNames.Count; $i++) {
      $centroid[$i] += $entry.vector[$i]
    }
  }

  for ($i = 0; $i -lt $featureNames.Count; $i++) {
    $centroid[$i] = $centroid[$i] / $group.Count
  }

  $centroids[$group.Name] = $centroid
}

function Predict-NearestCentroid {
  param(
    [double[]]$Vector,
    [hashtable]$Centroids
  )

  $bestSpecies = ""
  $bestDistance = [double]::PositiveInfinity

  foreach ($species in $Centroids.Keys) {
    $distance = Get-Distance -Left $Vector -Right $Centroids[$species]

    if ($distance -lt $bestDistance) {
      $bestDistance = $distance
      $bestSpecies = $species
    }
  }

  return $bestSpecies
}

function Predict-NearestNeighbor {
  param(
    [double[]]$Vector,
    [object[]]$TrainingVectors
  )

  $bestSpecies = ""
  $bestDistance = [double]::PositiveInfinity

  foreach ($entry in $TrainingVectors) {
    $distance = Get-Distance -Left $Vector -Right $entry.vector

    if ($distance -lt $bestDistance) {
      $bestDistance = $distance
      $bestSpecies = $entry.species
    }
  }

  return $bestSpecies
}

function Evaluate-Model {
  param(
    [string]$Name,
    [object[]]$Rows,
    [scriptblock]$Predictor
  )

  $predictions = New-Object System.Collections.Generic.List[object]
  $correct = 0

  foreach ($row in $Rows) {
    $vector = Get-NormalizedVector -Row $row -FeatureNames $featureNames -FeatureStats $featureStats
    $predictedSpecies = & $Predictor $vector

    if ($predictedSpecies -eq $row.species) {
      $correct++
    }

    [void]$predictions.Add([pscustomobject]@{
      actual = $row.species
      predicted = $predictedSpecies
    })
  }

  $predictionArray = @($predictions | ForEach-Object { $_ })

  return [pscustomobject]@{
    name = $Name
    correct = $correct
    total = $Rows.Count
    accuracy = ([double]$correct) / ([double]$Rows.Count)
    predictions = $predictionArray
  }
}

$trainSet = @($trainRows | ForEach-Object { $_ })
$testSet = @($testRows | ForEach-Object { $_ })
$majorityClass = ($trainSet | Group-Object species | Sort-Object Count -Descending | Select-Object -First 1).Name

$baselineResult = Evaluate-Model -Name "Majority class baseline" -Rows $testSet -Predictor {
  param($vector)
  return $majorityClass
}

$centroidResult = Evaluate-Model -Name "Nearest centroid classifier" -Rows $testSet -Predictor {
  param($vector)
  return Predict-NearestCentroid -Vector $vector -Centroids $centroids
}

$knnResult = Evaluate-Model -Name "1-nearest-neighbor classifier" -Rows $testSet -Predictor {
  param($vector)
  return Predict-NearestNeighbor -Vector $vector -TrainingVectors $trainingVectors
}

$allResults = @($baselineResult, $centroidResult, $knnResult)
$bestResult = $allResults | Sort-Object accuracy -Descending | Select-Object -First 1

$speciesSummary = @(
  $speciesOrder | ForEach-Object {
    $speciesName = $_
    $groupRows = @($cleanRows | Where-Object { $_.species -eq $speciesName })
    [pscustomobject]@{
      species = $speciesName
      count = $groupRows.Count
      avg_bill_length_mm = [math]::Round((Get-Mean -Values @($groupRows | ForEach-Object { $_.bill_length_mm })), 1)
      avg_flipper_length_mm = [math]::Round((Get-Mean -Values @($groupRows | ForEach-Object { $_.flipper_length_mm })), 1)
      avg_body_mass_g = [math]::Round((Get-Mean -Values @($groupRows | ForEach-Object { $_.body_mass_g })), 0)
    }
  }
)

$speciesSummary | Export-Csv -NoTypeInformation -Path $summaryPath

$resultRows = @(
  [pscustomobject]@{
    model = "Majority class baseline"
    short_label = "Baseline"
    accuracy_percent = [math]::Round($baselineResult.accuracy * 100, 1)
    correct_predictions = $baselineResult.correct
    total_test_samples = $baselineResult.total
    notes = "Always predicts $majorityClass."
  },
  [pscustomobject]@{
    model = "Nearest centroid classifier"
    short_label = "Centroid"
    accuracy_percent = [math]::Round($centroidResult.accuracy * 100, 1)
    correct_predictions = $centroidResult.correct
    total_test_samples = $centroidResult.total
    notes = "Classifies each penguin by the closest species center."
  },
  [pscustomobject]@{
    model = "1-nearest-neighbor classifier"
    short_label = "1-NN"
    accuracy_percent = [math]::Round($knnResult.accuracy * 100, 1)
    correct_predictions = $knnResult.correct
    total_test_samples = $knnResult.total
    notes = "Classifies each penguin by the closest training example."
  }
)

$resultRows | Export-Csv -NoTypeInformation -Path $resultsPath

$confusionRows = foreach ($actualSpecies in $speciesOrder) {
  foreach ($predictedSpecies in $speciesOrder) {
    [pscustomobject]@{
      actual_species = $actualSpecies
      predicted_species = $predictedSpecies
      count = @(
        $bestResult.predictions | Where-Object {
          $_.actual -eq $actualSpecies -and $_.predicted -eq $predictedSpecies
        }
      ).Count
    }
  }
}

$confusionRows | Export-Csv -NoTypeInformation -Path $confusionPath

New-BarChartSvg `
  -Title "Penguin Species Counts" `
  -Items $speciesSummary `
  -LabelProperty "species" `
  -ValueProperty "count" `
  -OutputPath $countChartPath `
  -ColorMap $speciesColors

New-BarChartSvg `
  -Title "Average Flipper Length by Species" `
  -Items $speciesSummary `
  -LabelProperty "species" `
  -ValueProperty "avg_flipper_length_mm" `
  -OutputPath $flipperChartPath `
  -ColorMap $speciesColors `
  -ValueSuffix " mm" `
  -Decimals 1

New-BarChartSvg `
  -Title "Model Accuracy Comparison" `
  -Items $resultRows `
  -LabelProperty "short_label" `
  -ValueProperty "accuracy_percent" `
  -OutputPath $accuracyChartPath `
  -ColorMap $speciesColors `
  -ValueSuffix "%" `
  -Decimals 1

$report = @"
# Palmer Penguins Species Classification

## Title

Palmer Penguins Species Classification

## Objective

Use a real-world penguin dataset to explore patterns, compare simple classifiers,
and practice an end-to-end machine learning workflow that includes cleaning,
feature selection, evaluation, and communication.

## Process

1. Downloaded the Palmer Penguins dataset.
2. Removed rows with missing numeric values or missing labels.
3. Used four numeric features: bill length, bill depth, flipper length, and body mass.
4. Split the cleaned dataset into deterministic training and test sets.
5. Compared a majority-class baseline, a nearest centroid classifier, and a
   1-nearest-neighbor classifier.
6. Exported results tables and visual summaries for the portfolio.

## Tools

- PowerShell
- CSV data processing
- Static SVG charts
- GitHub Pages compatible HTML, Markdown, and image assets

## Value Proposition

This project demonstrates that I can take raw data, structure an analysis,
build repeatable code, compare model behavior, and communicate results clearly in
a format that can be shared online.

## Dataset Snapshot

- Raw rows in source file: $($rawRows.Count)
- Clean rows used for analysis: $($cleanRows.Count)
- Training rows: $($trainRows.Count)
- Test rows: $($testRows.Count)

## Model Results

| Model | Accuracy | Correct / Total |
| --- | ---: | ---: |
| Majority class baseline | $($resultRows[0].accuracy_percent)% | $($resultRows[0].correct_predictions) / $($resultRows[0].total_test_samples) |
| Nearest centroid classifier | $($resultRows[1].accuracy_percent)% | $($resultRows[1].correct_predictions) / $($resultRows[1].total_test_samples) |
| 1-nearest-neighbor classifier | $($resultRows[2].accuracy_percent)% | $($resultRows[2].correct_predictions) / $($resultRows[2].total_test_samples) |

## Key Takeaways

- The majority baseline offers a quick reference point, but it ignores the
  penguins' feature values.
- The nearest centroid model performs strongly while staying simple and easy to
  explain.
- The 1-nearest-neighbor model achieved the best accuracy in this project,
  showing that even simple distance-based methods can separate these species well.

## Deliverables Included

- penguins.csv
- generate-artifact.ps1
- species-summary.csv
- model-results.csv
- best-model-confusion-matrix.csv
- species-counts.svg
- average-flipper-length.svg
- model-accuracy.svg

## Visuals

![Penguin species counts](species-counts.svg)

![Average flipper length by species](average-flipper-length.svg)

![Model accuracy comparison](model-accuracy.svg)
"@

Set-Content -Path $reportPath -Value $report
