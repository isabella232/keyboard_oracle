/*
Copyright 2020 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import 'dart:io';
import 'dart:math';

import 'package:trie_constructor/aksaras.dart';
import 'package:trie_constructor/src/word_info.dart';
import 'package:trie_constructor/suffix_trie.dart';

const defaultNumPredictions = 70;
const defaultTestSize = 5000;

// If set via its command line argument, the quality of this language model's
// predictions on its training data is measured using keyboard coverage,
// clicks-per-aksara, entropy and perplexity.
void testTriePerformance(List<WordInfo> sourceWords, bool testClicks,
    String trieFile, File testOutput) {
  var testWords = <WordInfo>[];
  var trainingWords = <WordInfo>[];
  setWordsData(sourceWords, testWords, trainingWords);
  var trie = getTestTrie(trieFile, trainingWords, testOutput);

  var probabilisticModelAccuracy = calculateKeyboardAccuracy(trie, testWords);
  print('Probabilistic model keyboard coverage: $probabilisticModelAccuracy');
  var entropy = calculateEntropy(trie, testWords);
  print('Entropy on test data: $entropy');
  var perplexity = calculatePerplexity(entropy);
  print('Perplexity on test data: $perplexity');

  if (testClicks) {
    calculateClicksPerAksara(trie, testWords);
  }
}

// Sets the training words, test words, and test words size for the
// performance-related tests.
void setWordsData(List<WordInfo> sourceWords, List<WordInfo> testWords,
    List<WordInfo> trainingWords) {
  // If the input data is too small for the test data to be 5000 lines long,
  // the size is set to be a tenth of the input data set's size.
  var testSize = defaultTestSize;
  if (testSize > sourceWords.length / 10) {
    testSize = (sourceWords.length / 10).floor();
  }
  // Every tenth word in the data set is added to the test set.
  for (var i = 0; i < testSize * 10; i++) {
    if (i % 10 == 0) {
      testWords.add(sourceWords[i]);
    } else {
      trainingWords.add((sourceWords[i]));
    }
  }
  // Any remaining words are added to the training set.
  trainingWords.addAll(sourceWords.sublist(testSize * 10));
}

SuffixTrie getTestTrie(
    String trieFile, List<WordInfo> trainingWords, File testOutput) {
  // The trie is constructed from the training words (or loaded from a binary
  // file if the file location is not null)
  SuffixTrie trie;
  if (trieFile != null) {
    var file = File(trieFile);
    var protoBytes = file.readAsBytesSync();
    trie = SuffixTrie(protoBytes);
  } else {
    trie = SuffixTrie.serialiseTrie(trainingWords, testOutput);
  }
  return trie;
}

// Calculates the entropy of the language model. This can be seen as a measure
// of the model's uncertaintly which means the lower it is the better.
double calculateEntropy(SuffixTrie trie, List<WordInfo> words) {
  var log2Prob = 0.0;
  var numAksarasTested = 0;
  for (var word in words) {
    var context = Aksaras(['']);
    for (var aksara in word.aksaras) {
      var probs = trie.getProbabilities(context);
      var p = probs[aksara];
      p ??= probs[SuffixTrie.unseenAksara];
      log2Prob += log(p) / ln2;
      context.add(aksara);
    }
    numAksarasTested += word.aksaras.length;
  }
  var entropy = -log2Prob / numAksarasTested;
  return entropy;
}

// Calculates the perplexity of the language model, which is 2^(entropy).
double calculatePerplexity(double entropy) {
  var perplexity = pow(2, entropy);
  return perplexity;
}

// Calculates the accuracy/coverage of single-aksara keyboard predictions.
// This test returns how likely it is that the aksara a user wants to type next
// is displayed on the keyboard. The percentage returned is weighted according
// to the frequency of the test words.
double calculateKeyboardAccuracy(SuffixTrie trie, List<WordInfo> words) {
  var modelScore = 0;
  var maxScore = 0;
  for (var word in words) {
    var context = Aksaras(['@']);
    for (var aksara in word.aksaras) {
      if (aksara != WordInfo.wordStartingSymbol) {
        maxScore += word.frequency;
        var predictions = <Aksaras>[];
        // Only using the model predictions as the frequency-based algorithm is
        // no longer compatible with this test. To get coverage-related results
        // for the frequency-based algorthm, refer to calculateClicksPerAksara.
        predictions =
            trie.getModelPredictions(context, defaultNumPredictions - 30);
        for (var prediction in predictions) {
          if (prediction.join() == aksara) {
            modelScore += word.frequency;
            break;
          }
        }
        context.add(aksara);
      }
    }
  }
  return modelScore / maxScore;
}

// Calculates the minimum number of keyboard clicks (key presses) needed to
// input every aksara in the test set and divides it by the number of aksaras.
// In this way, the average number of clicks needed to input an aksara is
// calculated. The average number of clicks needed to input a character is also
// calculated by keeping count of the number of characters in each aksara and
// dividing this total by the number of keyboard clicks
void calculateClicksPerAksara(SuffixTrie trie, List<WordInfo> words) {
  var totalClicks = 0;
  var totalAksaras = 0;
  var totalCharacters = 0;
  for (var word in words) {
    totalAksaras += word.aksaras.length - 1;
    totalCharacters += word.aksaras.join().length - 1;
    var context = Aksaras(['@']);
    var predictions = <Aksaras>[];
    for (var i = 1; i < word.aksaras.length;) {
      var foundMatch = false;
      predictions =
          trie.getMostLikelyPredictions(context, defaultNumPredictions);
      predictions.sort(((a, b) => b.length.compareTo(a.length)));
      for (var prediction in predictions) {
        if (i + prediction.length <= word.aksaras.length) {
          var pattern =
              List<String>.from(word.aksaras.sublist(i, i + prediction.length));
          if (pattern.join() == prediction.join()) {
            context.addAll(pattern);
            foundMatch = true;
            i += prediction.length;
            totalClicks++;
            break;
          }
        }
      }
      // If the current sub-aksara cannot be typed, its length (in characters)
      // + 1 is added to the totalClicks and we move onto the next sub-aksara.
      if (!foundMatch) {
        var currentAksara = word.aksaras[i].toString();
        context.add(currentAksara);
        i++;
        totalClicks += 1 + currentAksara.length;
      }
    }
  }
  print('${totalClicks / totalCharacters} clicks per character');
  print('${totalClicks / totalAksaras} clicks per aksara');
}
