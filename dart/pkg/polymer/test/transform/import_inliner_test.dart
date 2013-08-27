// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library polymer.test.transform.import_inliner_test;

import 'package:polymer/src/transform/import_inliner.dart';
import 'package:unittest/compact_vm_config.dart';
import 'package:unittest/unittest.dart';

import 'common.dart';

void main() {
  useCompactVMConfiguration();
  testPhases('no changes', [[new ImportedElementInliner()]], {
      'a|test.html': '<!DOCTYPE html><html></html>',
    }, {
      'a|test.html': '<!DOCTYPE html><html></html>',
    });

  testPhases('empty import', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="">' // empty href
          '</head></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import">'         // no href
          '</head></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body></body></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body></body></html>',
    });

  testPhases('shallow, no elements', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test2.html">'
          '</head></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body></body></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head></html>',
    });

  testPhases('shallow, elements, one import', [[new ImportedElementInliner()]],
    {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test2.html">'
          '</head></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>2</polymer-element></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>2</polymer-element>'
          '</body></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>2</polymer-element></html>',
    });

  testPhases('shallow, elements, many', [[new ImportedElementInliner()]],
    {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test2.html">'
          '<link rel="import" href="test3.html">'
          '</head></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>2</polymer-element></html>',
      'a|test3.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>3</polymer-element></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>2</polymer-element>'
          '<polymer-element>3</polymer-element>'
          '</body></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>2</polymer-element></html>',
      'a|test3.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>3</polymer-element></html>',
    });

  testPhases('deep, elements, one per file', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test2.html">'
          '</head></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="assets/b/test3.html">'
          '</head><body><polymer-element>2</polymer-element></html>',
      'b|asset/test3.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="packages/c/test4.html">'
          '</head><body><polymer-element>3</polymer-element></html>',
      'c|lib/test4.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>4</polymer-element></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>4</polymer-element>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>2</polymer-element></body></html>',
      'a|test2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>4</polymer-element>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>2</polymer-element></body></html>',
      'b|asset/test3.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>4</polymer-element>'
          '<polymer-element>3</polymer-element></body></html>',
      'c|lib/test4.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>4</polymer-element></html>',
    });

  testPhases('deep, elements, many imports', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test2a.html">'
          '<link rel="import" href="test2b.html">'
          '</head></html>',
      'a|test2a.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test3a.html">'
          '<link rel="import" href="test3b.html">'
          '</head><body><polymer-element>2a</polymer-element></body></html>',
      'a|test2b.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test4a.html">'
          '<link rel="import" href="test4b.html">'
          '</head><body><polymer-element>2b</polymer-element></body></html>',
      'a|test3a.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>3a</polymer-element></body></html>',
      'a|test3b.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>3b</polymer-element></body></html>',
      'a|test4a.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>4a</polymer-element></body></html>',
      'a|test4b.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>4b</polymer-element></body></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3a</polymer-element>'
          '<polymer-element>3b</polymer-element>'
          '<polymer-element>2a</polymer-element>'
          '<polymer-element>4a</polymer-element>'
          '<polymer-element>4b</polymer-element>'
          '<polymer-element>2b</polymer-element>'
          '</body></html>',
      'a|test2a.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3a</polymer-element>'
          '<polymer-element>3b</polymer-element>'
          '<polymer-element>2a</polymer-element>'
          '</body></html>',
      'a|test2b.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>4a</polymer-element>'
          '<polymer-element>4b</polymer-element>'
          '<polymer-element>2b</polymer-element>'
          '</body></html>',
      'a|test3a.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3a</polymer-element>'
          '</body></html>',
      'a|test3b.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3b</polymer-element>'
          '</body></html>',
      'a|test4a.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>4a</polymer-element>'
          '</body></html>',
      'a|test4b.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>4b</polymer-element>'
          '</body></html>',
    });

  testPhases('imports cycle, 1-step lasso', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_1.html">'
          '</head></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_2.html">'
          '</head><body><polymer-element>1</polymer-element></html>',
      'a|test_2.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_1.html">'
          '</head><body><polymer-element>2</polymer-element></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>2</polymer-element>'
          '<polymer-element>1</polymer-element></body></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>2</polymer-element>'
          '<polymer-element>1</polymer-element></body></html>',
      'a|test_2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>1</polymer-element>'
          '<polymer-element>2</polymer-element></body></html>',
    });

  testPhases('imports cycle, 2-step lasso', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_1.html">'
          '</head></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_2.html">'
          '</head><body><polymer-element>1</polymer-element></html>',
      'a|test_2.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_3.html">'
          '</head><body><polymer-element>2</polymer-element></html>',
      'a|test_3.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_1.html">'
          '</head><body><polymer-element>3</polymer-element></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>2</polymer-element>'
          '<polymer-element>1</polymer-element></body></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>2</polymer-element>'
          '<polymer-element>1</polymer-element></body></html>',
      'a|test_2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>1</polymer-element>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>2</polymer-element></body></html>',
      'a|test_3.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>2</polymer-element>'
          '<polymer-element>1</polymer-element>'
          '<polymer-element>3</polymer-element></body></html>',
    });

  testPhases('imports cycle, self cycle', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_1.html">'
          '</head></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_1.html">'
          '</head><body><polymer-element>1</polymer-element></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>1</polymer-element></body></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>1</polymer-element></body></html>',
    });

  testPhases('imports DAG', [[new ImportedElementInliner()]], {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_1.html">'
          '<link rel="import" href="test_2.html">'
          '</head></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_3.html">'
          '</head><body><polymer-element>1</polymer-element></body></html>',
      'a|test_2.html':
          '<!DOCTYPE html><html><head>'
          '<link rel="import" href="test_3.html">'
          '</head><body><polymer-element>2</polymer-element></body></html>',
      'a|test_3.html':
          '<!DOCTYPE html><html><head>'
          '</head><body><polymer-element>3</polymer-element></body></html>',
    }, {
      'a|test.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>1</polymer-element>'
          '<polymer-element>2</polymer-element></body></html>',
      'a|test_1.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>1</polymer-element></body></html>',
      'a|test_2.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3</polymer-element>'
          '<polymer-element>2</polymer-element></body></html>',
      'a|test_3.html':
          '<!DOCTYPE html><html><head>'
          '</head><body>'
          '<polymer-element>3</polymer-element></body></html>',
    });
}