package procgen

import asset "../asset"
import "core:math"

// Spatial ordering and bounding volumes for the cluster builder.
//
// Morton (Z-order) interleaving of the quantized triangle centroid gives a
// one-dimensional key whose neighbours in sort order are neighbours in space.
// Cutting that order into fixed runs is a crude partitioner compared with a
// graph cut, but it needs no dependency, no tuning, and produces the same
// answer every run - which the cook step's byte-for-byte reproducibility needs.

@(private)
_cluster_keys :: proc(
	bounds: asset.Bounds_3D,
	storage: Cluster_Build_Storage,
	span_first, triangles: int,
) {
	assert(triangles > 0, "_cluster_keys: empty span")
	assert(triangles <= len(storage.keys), "_cluster_keys: key storage too small")
	extent := asset.Vec3 {
		max(bounds.maximum[0] - bounds.minimum[0], 0),
		max(bounds.maximum[1] - bounds.minimum[1], 0),
		max(bounds.maximum[2] - bounds.minimum[2], 0),
	}
	for triangle in 0 ..< triangles {
		base := span_first + triangle * 3
		centroid: asset.Vec3
		for corner in 0 ..< 3 {
			centroid += storage.vertices[storage.indices[base + corner]].position
		}
		centroid /= 3
		cell: [3]u32
		for axis in 0 ..< 3 {
			normalized := f32(0)
			if extent[axis] > 0 {
				normalized = (centroid[axis] - bounds.minimum[axis]) / extent[axis]
			}
			normalized = clamp(normalized, 0, 1)
			cell[axis] = u32(math.round(normalized * CLUSTER_BUILD_MORTON_SCALE))
		}
		storage.keys[triangle] = {_cluster_morton(cell), u32(triangle), 0}
	}
}

@(private)
_cluster_morton :: proc(cell: [3]u32) -> u64 {
	assert(cell[0] <= u32(CLUSTER_BUILD_MORTON_SCALE), "_cluster_morton: x out of range")
	assert(cell[2] <= u32(CLUSTER_BUILD_MORTON_SCALE), "_cluster_morton: z out of range")
	result := u64(0)
	for bit in 0 ..< uint(CLUSTER_BUILD_MORTON_BITS) {
		for axis in 0 ..< uint(3) {
			set := u64((cell[axis] >> bit) & 1)
			result |= set << (bit * 3 + axis)
		}
	}
	return result
}

// Ties are broken by the original triangle index so the order is total and the
// heapsort's internal swaps cannot change the outcome.
@(private)
_cluster_key_less :: proc(first, second: Cluster_Key) -> bool {
	if first.code != second.code do return first.code < second.code
	return first.triangle < second.triangle
}

// Applies the sorted order to the index buffer through the working copy, so a
// group's triangles become one contiguous range.
@(private)
_cluster_reorder :: proc(
	storage: Cluster_Build_Storage,
	span_first, triangles: int,
) -> bool {
	assert(triangles > 0, "_cluster_reorder: empty span")
	assert(triangles <= len(storage.keys), "_cluster_reorder: key storage too small")
	if triangles * 3 > len(storage.scratch_indices) do return false
	for triangle in 0 ..< triangles {
		source := int(storage.keys[triangle].triangle)
		for corner in 0 ..< 3 {
			storage.scratch_indices[triangle * 3 + corner] =
				storage.indices[span_first + source * 3 + corner]
		}
	}
	for offset in 0 ..< triangles * 3 {
		storage.indices[span_first + offset] = storage.scratch_indices[offset]
	}
	return true
}

// A cluster's bounding sphere is the centre of its position bounds plus the
// distance to the farthest vertex. It is not the minimal sphere, but it is
// deterministic, cheap, and conservative - which is all a cull test needs.
@(private)
_cluster_sphere :: proc(
	storage: Cluster_Build_Storage,
	first_index, index_count: u32,
) -> (
	asset.Vec3,
	f32,
) {
	assert(index_count > 0, "_cluster_sphere: empty cluster")
	assert(index_count % 3 == 0, "_cluster_sphere: incomplete triangle")
	first := storage.vertices[storage.indices[first_index]].position
	bounds := asset.Bounds_3D {
		minimum = first,
		maximum = first,
	}
	for step in 1 ..< index_count {
		position := storage.vertices[storage.indices[first_index + step]].position
		for axis in 0 ..< 3 {
			bounds.minimum[axis] = min(bounds.minimum[axis], position[axis])
			bounds.maximum[axis] = max(bounds.maximum[axis], position[axis])
		}
	}
	center := (bounds.minimum + bounds.maximum) * 0.5
	radius := f32(0)
	for step in 0 ..< index_count {
		position := storage.vertices[storage.indices[first_index + step]].position
		delta := position - center
		radius = max(radius, math.sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]))
	}
	return center, radius
}

// The group sphere must contain every child sphere, because a group's error is
// what replaces those children and the cull test has to agree.
@(private)
_cluster_group_sphere :: proc(
	storage: Cluster_Build_Storage,
	first_child, child_count: int,
) -> (
	asset.Vec3,
	f32,
) {
	assert(child_count > 0, "_cluster_group_sphere: empty group")
	assert(first_child >= 0, "_cluster_group_sphere: negative child index")
	center := asset.Vec3{}
	for offset in 0 ..< child_count {
		center += storage.clusters[first_child + offset].center
	}
	center /= f32(child_count)
	radius := f32(0)
	for offset in 0 ..< child_count {
		child := storage.clusters[first_child + offset]
		delta := child.center - center
		distance := math.sqrt(
			delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2],
		)
		radius = max(radius, distance + child.radius)
	}
	return center, radius
}
