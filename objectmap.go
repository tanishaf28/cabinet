package main

import (
	"fmt"
	"math/rand"
	"sync"
)

// ObjectMeta describes one entry in the fixed object pool used to drive the
// independent/dependent workload split (see parameters.go's -numobjects/-indep).
// Unlike woc's registry, there is no Owner/hash-ring field: Cabinet runs a
// single quorum-based consensus path, not per-object ownership/consensus.
type ObjectMeta struct {
	Index int
	ID    string
	Type  int
}

var (
	objectRegistryOnce sync.Once
	objectByIndex      map[int]*ObjectMeta
	independentIdx     []int
	dependentIdx       []int
)

// InitObjectRegistry builds the numObjects-sized object pool, split into
// independent/dependent by indepRatio. This is deployment-time-static and
// deterministic, so every server and client computes it independently —
// no leader-side precompute-and-distribute step is needed, unlike Cabinet's
// previous preloadCabinetObjects warmup.
func InitObjectRegistry() {
	objectRegistryOnce.Do(func() {
		indepCount := int(float64(numObjects) * indepRatio / 100.0)

		objectByIndex = make(map[int]*ObjectMeta, numObjects)

		for i := 0; i < numObjects; i++ {
			objType := DependentObject
			if i < indepCount {
				objType = IndependentObject
			}
			meta := &ObjectMeta{Index: i, ID: fmt.Sprintf("obj-%d", i), Type: objType}
			objectByIndex[i] = meta

			if objType == IndependentObject {
				independentIdx = append(independentIdx, i)
			} else {
				dependentIdx = append(dependentIdx, i)
			}
		}
	})
}

// ObjectByIndex returns the i-th object's metadata (nil if out of range).
func ObjectByIndex(i int) *ObjectMeta {
	return objectByIndex[i]
}

// PickObjectType returns IndependentObject with probability indepRatio%,
// DependentObject otherwise. Bucket-empty checks come first: indepCount's
// rounding (see InitObjectRegistry) can zero out a bucket that indepRatio
// still has nonzero probability of selecting, which would otherwise hand
// PickObjectOfType a type with no objects to pick from.
func PickObjectType() int {
	if len(independentIdx) == 0 {
		return DependentObject
	}
	if len(dependentIdx) == 0 {
		return IndependentObject
	}
	if rand.Float64()*100 < indepRatio {
		return IndependentObject
	}
	return DependentObject
}

// PickObjectOfType returns a uniformly random object of the given type.
func PickObjectOfType(objType int) *ObjectMeta {
	indices := dependentIdx
	if objType == IndependentObject {
		indices = independentIdx
	}
	if len(indices) == 0 {
		return nil
	}
	return objectByIndex[indices[rand.Intn(len(indices))]]
}
