/*
 * Copyright (c) 2012, the Dart project authors.
 * 
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 * 
 * http://www.eclipse.org/legal/epl-v10.html
 * 
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
package com.google.dart.tools.core.analysis;

import com.google.dart.engine.utilities.io.PrintStringWriter;
import com.google.dart.tools.core.AbstractDartCoreTest;
import com.google.dart.tools.core.analysis.ScanTask.DartFileType;
import com.google.dart.tools.core.test.util.FileUtilities;
import com.google.dart.tools.core.test.util.TestUtilities;

import static com.google.dart.tools.core.analysis.AnalysisTestUtilities.assertTrackedLibraryFiles;
import static com.google.dart.tools.core.analysis.ScanTask.DartFileType.Library;
import static com.google.dart.tools.core.analysis.ScanTask.DartFileType.PartOf;
import static com.google.dart.tools.core.analysis.ScanTask.DartFileType.Unknown;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;

public class ScanTaskTest extends AbstractDartCoreTest {

  private static final long FIVE_MINUTES_MS = 300000;
  private static final byte[] BUFFER = new byte[1024];

  private static File tempDir;
  private static File moneyDir;
  private static File libraryFile;
  private static File dartFile;
  private static File doesNotExist;

  /**
   * Called once prior to executing the first test in this class
   */
  public static void setUpOnce() throws Exception {
    tempDir = TestUtilities.createTempDirectory();
    moneyDir = new File(tempDir, "Money");
    TestUtilities.copyPluginRelativeContent("Money", moneyDir);
    libraryFile = new File(moneyDir, "money.dart");
    assertTrue(libraryFile.exists());
    dartFile = new File(moneyDir, "simple_money.dart");
    assertTrue(dartFile.exists());
    doesNotExist = new File(moneyDir, "doesNotExist.dart");
  }

  /**
   * Called once after executing the last test in this class
   */
  public static void tearDownOnce() {
    FileUtilities.delete(tempDir);
    tempDir = null;
  }

  private AnalysisServerAdapter server;
  private Listener listener;

  public void test_scan_directory() throws Exception {
    assertTrackedLibraryFiles(server);
    server.scan(moneyDir, true);
    server.start();
    listener.waitForIdle(1, FIVE_MINUTES_MS);
    assertTrackedLibraryFiles(server, libraryFile);
    server.assertAnalyzeContext(true);
  }

  public void test_scan_doesNotExist() throws Exception {
    assertTrackedLibraryFiles(server);
    server.scan(doesNotExist, true);
    server.start();
    listener.waitForIdle(1, FIVE_MINUTES_MS);
    assertTrackedLibraryFiles(server);
    server.assertAnalyzeContext(false);
  }

  public void test_scan_library() throws Exception {
    assertTrackedLibraryFiles(server);
    server.scan(libraryFile, true);
    server.start();
    listener.waitForIdle(1, FIVE_MINUTES_MS);
    assertTrackedLibraryFiles(server, libraryFile);
    server.assertAnalyzeContext(true);
  }

  public void test_scan_libraryThenSource() throws Exception {
    test_scan_library();
    server.resetAnalyzeContext();
    server.scan(dartFile, true);
    listener.waitForIdle(2, FIVE_MINUTES_MS);
    assertTrackedLibraryFiles(server, libraryFile);
    server.assertAnalyzeContext(false);
  }

  public void test_scan_source() throws Exception {
    assertTrackedLibraryFiles(server);
    server.scan(dartFile, true);
    server.start();
    listener.waitForIdle(1, FIVE_MINUTES_MS);
    assertTrackedLibraryFiles(server, dartFile);
    server.assertAnalyzeContext(true);
  }

  public void test_scan_sourceThenLibrary() throws Exception {
    test_scan_source();
    server.resetAnalyzeContext();
    server.scan(libraryFile, true);
    listener.waitForIdle(2, FIVE_MINUTES_MS);
    assertTrackedLibraryFiles(server, libraryFile);
    server.assertAnalyzeContext(true);
  }

  public void test_scanContent_import() throws Exception {
    PrintStringWriter writer = new PrintStringWriter();
    writer.println("import 'foo';");
    writer.println("main() { }");
    assertScanContent(writer.toString(), Library);
  }

  public void test_scanContent_library() throws Exception {
    PrintStringWriter writer = new PrintStringWriter();
    writer.println("library 'foo';");
    writer.println("main() { }");
    assertScanContent(writer.toString(), Library);
  }

  public void test_scanContent_library2() throws Exception {
    PrintStringWriter writer = new PrintStringWriter();
    writer.println("// filler filler filler");
    writer.println("library 'foo';");
    writer.println("main() { }");
    assertScanContent(writer.toString(), Library);
  }

  public void test_scanContent_library3() throws Exception {
    PrintStringWriter writer = new PrintStringWriter();
    writer.println("/* filler filler filler");
    writer.println("filler filler filler */ library 'foo';");
    writer.println("main() { }");
    assertScanContent(writer.toString(), Library);
  }

  public void test_scanContent_part() throws Exception {
    PrintStringWriter writer = new PrintStringWriter();
    writer.println("part 'foo';");
    writer.println("main() { }");
    assertScanContent(writer.toString(), Library);
  }

  public void test_scanContent_partOf() throws Exception {
    PrintStringWriter writer = new PrintStringWriter();
    writer.println("part of 'foo';");
    writer.println("main() { }");
    assertScanContent(writer.toString(), PartOf);
  }

  public void test_scanContent_partOf2() throws Exception {
    PrintStringWriter writer = new PrintStringWriter();
    writer.println("// filler filler filler");
    writer.println("part of 'foo';");
    writer.println("main() { }");
    assertScanContent(writer.toString(), PartOf);
  }

  public void test_scanContent_unknown() throws Exception {
    assertScanContent("hello this is a random file", Unknown);
  }

  public void test_scanContent_unknown2() throws Exception {
    assertScanContent("'library' not", Unknown);
  }

  public void test_scanContent_unknown3() throws Exception {
    assertScanContent("> library", Unknown);
  }

  public void test_scanContent_unknown4() throws Exception {
    assertScanContent("4.3 library", Unknown);
  }

  public void test_scanContent_unknown5() throws Exception {
    assertScanContent("libraryA foo", Unknown);
  }

  public void test_scanContent_unknown6() throws Exception {
    assertScanContent("partition foo", Unknown);
  }

  public void test_scanContent_unknown7() throws Exception {
    assertScanContent("part ofA foo", Unknown);
  }

  @Override
  protected void setUp() throws Exception {
    server = new AnalysisServerAdapter();
    listener = new Listener(server);
  }

  @Override
  protected void tearDown() throws Exception {
    server.stop();
  }

  private void assertScanContent(String content, DartFileType expected) throws IOException {
    DartFileType actual = ScanTask.scanContent(new ByteArrayInputStream(content.getBytes()), BUFFER);
    assertEquals(expected, actual);
  }
}
