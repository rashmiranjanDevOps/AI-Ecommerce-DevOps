variable "repositories" {
  description = "Repository names to create."
  type        = list(string)
}

variable "keep_images" {
  description = "Number of tagged images to keep per repository."
  type        = number
  default     = 20
}

variable "force_delete" {
  description = "Delete the repository even if it still contains images."
  type        = bool
  default     = false
}
