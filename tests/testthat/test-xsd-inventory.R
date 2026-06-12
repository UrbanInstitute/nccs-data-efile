# Synthetic XSD exercising every traversal path the walker must handle:
# named type, anonymous inline type, ref, repeating cardinality,
# annotation, complexContent/extension base, and a recursive type (cycle).
# Uses the `xsd:` prefix (as the real IRS bundles do) to prove the walk is
# namespace-URI driven, not prefix driven.
make_inventory_fixture <- function(dir) {
  xsd <- '<?xml version="1.0"?>
<xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <xsd:element name="Root" type="RootType"/>
  <xsd:complexType name="RootType">
    <xsd:sequence>
      <xsd:element name="Amount" type="USAmountType">
        <xsd:annotation><xsd:documentation>Money field</xsd:documentation></xsd:annotation>
      </xsd:element>
      <xsd:element name="Items" type="ItemType" minOccurs="0" maxOccurs="unbounded"/>
      <xsd:element name="Tags" type="TextType" minOccurs="0" maxOccurs="3"/>
      <xsd:element ref="SharedThing" minOccurs="0"/>
      <xsd:element name="Inline">
        <xsd:complexType><xsd:sequence>
          <xsd:element name="InnerLeaf" type="TextType"/>
        </xsd:sequence></xsd:complexType>
      </xsd:element>
      <xsd:element name="Node" type="NodeType"/>
    </xsd:sequence>
  </xsd:complexType>
  <xsd:complexType name="ItemType">
    <xsd:sequence><xsd:element name="ItemName" type="TextType"/></xsd:sequence>
  </xsd:complexType>
  <xsd:element name="SharedThing" type="TextType">
    <xsd:annotation><xsd:documentation>shared</xsd:documentation></xsd:annotation>
  </xsd:element>
  <xsd:complexType name="NodeType">
    <xsd:sequence>
      <xsd:element name="Leaf" type="TextType"/>
      <xsd:element name="Child" type="NodeType"/>
    </xsd:sequence>
  </xsd:complexType>
  <xsd:element name="Derived" type="DerivedType"/>
  <xsd:complexType name="BaseType">
    <xsd:sequence><xsd:element name="BaseLeaf" type="TextType"/></xsd:sequence>
  </xsd:complexType>
  <xsd:complexType name="DerivedType">
    <xsd:complexContent><xsd:extension base="BaseType">
      <xsd:sequence><xsd:element name="ExtraLeaf" type="TextType"/></xsd:sequence>
    </xsd:extension></xsd:complexContent>
  </xsd:complexType>
</xsd:schema>'
  writeLines(xsd, file.path(dir, "fixture.xsd"))
}

build_fixture_inventory <- function(roots) {
  dir <- tempfile("xsdinv_")
  dir.create(dir)
  make_inventory_fixture(dir)
  build_xsd_inventory("2024", "5.0", xsd_dir = dir, roots = roots)
}

root_root <- list(list(name = "Root", xpath = "/R/Root"))

test_that("walker enumerates leaves with type, cardinality, parent path", {
  inv <- build_fixture_inventory(root_root)
  amt <- inv[inv$xpath == "/R/Root/Amount", ]
  expect_equal(nrow(amt), 1)
  expect_equal(amt$xsd_type, "USAmountType")
  expect_true(amt$is_leaf)
  expect_equal(amt$parent_path, "/R/Root")
  expect_equal(amt$annotation, "Money field")
  expect_equal(amt$min_occurs, "1")
  expect_equal(amt$max_occurs, "1")
})

test_that("repeating element carries unbounded maxOccurs and descends", {
  inv <- build_fixture_inventory(root_root)
  items <- inv[inv$xpath == "/R/Root/Items", ]
  expect_equal(items$min_occurs, "0")
  expect_equal(items$max_occurs, "unbounded")
  expect_false(items$is_leaf)
  expect_true("/R/Root/Items/ItemName" %in% inv$xpath)
})

test_that("repeating flag marks unbounded elements and their descendants", {
  inv <- build_fixture_inventory(root_root)
  # the unbounded group root is itself repeating ...
  expect_true(inv$repeating[inv$xpath == "/R/Root/Items"])
  # ... and so is a scalar leaf nested under it (inherited down the path)
  expect_true(inv$repeating[inv$xpath == "/R/Root/Items/ItemName"])
  # a bounded maxOccurs>1 leaf is multi-valued => repeating (ADR 0004 s1)
  tags <- inv[inv$xpath == "/R/Root/Tags", ]
  expect_equal(tags$max_occurs, "3")
  expect_true(tags$is_leaf)
  expect_true(tags$repeating)
  # a maxOccurs="1" leaf, and the form root, are not repeating
  expect_false(inv$repeating[inv$xpath == "/R/Root/Amount"])
  expect_false(inv$repeating[inv$xpath == "/R/Root"])
  expect_false(inv$repeating[inv$xpath == "/R/Root/SharedThing"])
})

test_that("is_leaf & !repeating selects exactly the non-repeating scalar leaves", {
  inv <- build_fixture_inventory(root_root)
  scalars <- inv$xpath[inv$is_leaf & !inv$repeating]
  # present: leaves not under any unbounded ancestor
  expect_true(all(c("/R/Root/Amount", "/R/Root/SharedThing",
                    "/R/Root/Inline/InnerLeaf", "/R/Root/Node/Leaf") %in% scalars))
  # absent: a leaf under the unbounded Items group, and a bounded-multi leaf
  expect_false("/R/Root/Items/ItemName" %in% scalars)
  expect_false("/R/Root/Tags" %in% scalars)
})

test_that("repeating is a logical column", {
  inv <- build_fixture_inventory(root_root)
  expect_type(inv$repeating, "logical")
  expect_false(anyNA(inv$repeating))
})

test_that("ref resolves to the global element's type and annotation", {
  inv <- build_fixture_inventory(root_root)
  st <- inv[inv$xpath == "/R/Root/SharedThing", ]
  expect_equal(nrow(st), 1)
  expect_equal(st$xsd_type, "TextType")
  expect_true(st$is_leaf)
  expect_equal(st$min_occurs, "0")     # cardinality from the ref site
  expect_equal(st$annotation, "shared") # docs from the global element
})

test_that("anonymous inline complexType is descended", {
  inv <- build_fixture_inventory(root_root)
  expect_equal(inv$xsd_type[inv$xpath == "/R/Root/Inline"], "(anonymous)")
  expect_true("/R/Root/Inline/InnerLeaf" %in% inv$xpath)
})

test_that("recursive type is truncated, not infinite", {
  inv <- build_fixture_inventory(root_root)
  child <- inv[inv$xpath == "/R/Root/Node/Child", ]
  expect_equal(nrow(child), 1)
  expect_true(child$truncated)
  # cycle guard stops descent: the grandchild Leaf under Child is absent
  expect_false("/R/Root/Node/Child/Leaf" %in% inv$xpath)
  # but Node's own Leaf (first visit) is present
  expect_true("/R/Root/Node/Leaf" %in% inv$xpath)
})

test_that("complexContent/extension pulls in base and extension elements", {
  inv <- build_fixture_inventory(list(list(name = "Derived", xpath = "/D/Derived")))
  expect_true("/D/Derived/BaseLeaf" %in% inv$xpath)   # from BaseType
  expect_true("/D/Derived/ExtraLeaf" %in% inv$xpath)  # from the extension
})

test_that("output is deduplicated on xpath", {
  inv <- build_fixture_inventory(root_root)
  expect_equal(anyDuplicated(inv$xpath), 0L)
})
